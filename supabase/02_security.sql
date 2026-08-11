-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 02_security.sql
-- 범위: 보안 헬퍼 함수, Auth 동기화, 작품 상태 통제, 댓글 검증, 좋아요 RPC,
--       RLS 정책만 정의한다.
-- 이 파일에는 Storage 정책, 시드 데이터, 롤백 스크립트를 넣지 않는다.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. public.is_admin()
--    현재 세션(auth.uid())의 profiles.role이 admin인지 확인한다.
-- -------------------------------------------------------------------------
CREATE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE id = auth.uid()
          AND role = 'admin'
    );
$$;

REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_admin() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;

-- -------------------------------------------------------------------------
-- 2. public.manages_exhibition(UUID)
--    현재 사용자가 해당 전시관의 담당자로 매핑되어 있고,
--    profiles.role이 manager인 경우에만 true를 반환한다.
-- -------------------------------------------------------------------------
CREATE FUNCTION public.manages_exhibition(target_exhibition_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.exhibition_managers em
        JOIN public.profiles p ON p.id = em.profile_id
        WHERE em.exhibition_id = target_exhibition_id
          AND em.profile_id = auth.uid()
          AND p.role = 'manager'
    );
$$;

REVOKE ALL ON FUNCTION public.manages_exhibition(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manages_exhibition(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.manages_exhibition(UUID) TO authenticated;


-- =========================================================================
-- 3~4. Auth 사용자와 profiles 자동 동기화
-- =========================================================================

CREATE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.profiles (id, display_name, role, manager_type)
    VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data ->> 'name', '신규 등록자'),
        'pending',
        NULL
    )
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM anon;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM authenticated;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();


-- =========================================================================
-- 5. 작품 상태 통제
-- =========================================================================

CREATE FUNCTION public.enforce_artwork_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF public.is_admin() THEN
        -- admin이 status를 approved로 저장하려는 모든 경로(RPC를 거치지 않은
        -- 직접 UPDATE 포함)에서 개인정보 활용 동의 없이는 승인을 허용하지 않는다.
        -- 01_schema.sql의 chk_artworks_approval_requires_consent CHECK 제약이
        -- 동일 규칙의 최종 방어선이며, 이 트리거는 더 이른 시점에 명확한
        -- 오류 메시지로 차단하기 위한 것이다.
        IF NEW.status = 'approved' AND NOT NEW.consent_confirmed THEN
            RAISE EXCEPTION '개인정보 활용 동의가 완료되지 않아 승인할 수 없습니다.';
        END IF;

        IF NEW.status = 'approved' THEN
            NEW.approved_by := auth.uid();
            NEW.approved_at := timezone('utc', now());
        END IF;
    ELSE
        -- admin이 아닌 경우(manager)에는 등록/수정 모두 status를 pending으로 되돌리고
        -- 기존 승인 이력(approved_by, approved_at)을 무효화해 manager의 자기 승인을 차단한다.
        NEW.status := 'pending';
        NEW.approved_by := NULL;
        NEW.approved_at := NULL;
    END IF;

    NEW.updated_at := timezone('utc', now());
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_artwork_status() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_artwork_status() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_artwork_status() FROM authenticated;

DROP TRIGGER IF EXISTS trg_enforce_artwork_status ON public.artworks;

CREATE TRIGGER trg_enforce_artwork_status
    BEFORE INSERT OR UPDATE ON public.artworks
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_artwork_status();


-- -------------------------------------------------------------------------
-- 6. public.approve_artwork(UUID) : admin 전용 승인 RPC
-- -------------------------------------------------------------------------
CREATE FUNCTION public.approve_artwork(target_artwork_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '권한 거부: 관리자만 작품을 승인할 수 있습니다.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.artworks WHERE id = target_artwork_id) THEN
        RAISE EXCEPTION '대상 작품이 존재하지 않습니다.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.artworks
        WHERE id = target_artwork_id AND consent_confirmed = true
    ) THEN
        RAISE EXCEPTION '개인정보 활용 동의가 완료되지 않아 승인할 수 없습니다.';
    END IF;

    UPDATE public.artworks
    SET status = 'approved',
        approved_by = auth.uid(),
        approved_at = timezone('utc', now()),
        updated_at = timezone('utc', now()),
        rejection_reason = NULL
    WHERE id = target_artwork_id;
END;
$$;

-- -------------------------------------------------------------------------
-- 7. public.reject_artwork(UUID, TEXT) : admin 전용 반려 RPC
-- -------------------------------------------------------------------------
CREATE FUNCTION public.reject_artwork(target_artwork_id UUID, reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_reason TEXT;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '권한 거부: 관리자만 작품을 반려할 수 있습니다.';
    END IF;

    v_reason := trim(coalesce(reason, ''));

    IF length(v_reason) = 0 THEN
        RAISE EXCEPTION '반려 사유는 필수입니다.';
    END IF;

    IF length(v_reason) > 500 THEN
        RAISE EXCEPTION '반려 사유는 500자를 초과할 수 없습니다.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.artworks WHERE id = target_artwork_id) THEN
        RAISE EXCEPTION '대상 작품이 존재하지 않습니다.';
    END IF;

    UPDATE public.artworks
    SET status = 'rejected',
        rejection_reason = v_reason,
        approved_by = NULL,
        approved_at = NULL,
        updated_at = timezone('utc', now())
    WHERE id = target_artwork_id;
END;
$$;

-- -------------------------------------------------------------------------
-- 8. public.hide_artwork(UUID) : admin 전용 숨김 처리 RPC
-- -------------------------------------------------------------------------
CREATE FUNCTION public.hide_artwork(target_artwork_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '권한 거부: 관리자만 작품을 숨김 처리할 수 있습니다.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.artworks WHERE id = target_artwork_id) THEN
        RAISE EXCEPTION '대상 작품이 존재하지 않습니다.';
    END IF;

    UPDATE public.artworks
    SET status = 'hidden',
        updated_at = timezone('utc', now())
    WHERE id = target_artwork_id;
END;
$$;

REVOKE ALL ON FUNCTION public.approve_artwork(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_artwork(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.approve_artwork(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.reject_artwork(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_artwork(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.reject_artwork(UUID, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.hide_artwork(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hide_artwork(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.hide_artwork(UUID) TO authenticated;


-- =========================================================================
-- 9. 댓글 검증
-- =========================================================================

CREATE FUNCTION public.validate_and_sanitize_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_content TEXT;
    v_artwork_status TEXT;
    v_exhibition_visibility TEXT;
    v_allow_comments BOOLEAN;
BEGIN
    v_content := trim(NEW.content);

    IF length(v_content) = 0 THEN
        RAISE EXCEPTION '댓글 내용은 비어 있을 수 없습니다.';
    END IF;

    IF length(v_content) > 500 THEN
        RAISE EXCEPTION '댓글은 500자를 초과할 수 없습니다.';
    END IF;

    SELECT aw.status, ex.visibility, ex.allow_comments
    INTO v_artwork_status, v_exhibition_visibility, v_allow_comments
    FROM public.artworks aw
    JOIN public.exhibitions ex ON ex.id = aw.exhibition_id
    WHERE aw.id = NEW.artwork_id;

    IF v_artwork_status IS NULL THEN
        RAISE EXCEPTION '대상 작품이 존재하지 않습니다.';
    END IF;

    IF v_artwork_status != 'approved' THEN
        RAISE EXCEPTION '승인된 작품에만 댓글을 등록할 수 있습니다.';
    END IF;

    IF v_exhibition_visibility != 'public' THEN
        RAISE EXCEPTION '공개된 전시관의 작품에만 댓글을 등록할 수 있습니다.';
    END IF;

    IF NOT v_allow_comments THEN
        RAISE EXCEPTION '해당 전시관은 댓글 작성을 허용하지 않습니다.';
    END IF;

    -- 저장값은 원문을 그대로 유지한다. HTML 특수문자를 DB에서 임의로 치환해
    -- 원문을 손상시키지 않고, 화면 출력 시 프런트엔드에서 textContent로
    -- 렌더링하여 스크립트 삽입을 방지하는 방식을 전제로 한다.
    NEW.content := v_content;
    NEW.status := 'pending';

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_and_sanitize_comment() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_and_sanitize_comment() FROM anon;
REVOKE ALL ON FUNCTION public.validate_and_sanitize_comment() FROM authenticated;

DROP TRIGGER IF EXISTS trg_validate_and_sanitize_comment ON public.artwork_comments;

CREATE TRIGGER trg_validate_and_sanitize_comment
    BEFORE INSERT ON public.artwork_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_and_sanitize_comment();


-- =========================================================================
-- 10. public.toggle_artwork_like(UUID, TEXT) : 세션 기반 좋아요 토글 RPC
--     주의: 01_schema.sql에는 artworks.likes 캐시 컬럼이 없으므로
--     매 호출마다 artwork_likes를 COUNT하여 반환하며 별도 캐시는 갱신하지 않는다.
--     동일 브라우저 세션 기준 중복만 방지할 뿐, 동일인이 다른 세션이나
--     기기로 접속하면 중복 집계될 수 있다.
-- =========================================================================

CREATE FUNCTION public.toggle_artwork_like(target_artwork_id UUID, client_session TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_session TEXT;
    v_artwork_status TEXT;
    v_exhibition_visibility TEXT;
    v_liked_exists BOOLEAN;
    v_action TEXT;
    v_likes_count INTEGER;
BEGIN
    v_session := trim(coalesce(client_session, ''));

    IF length(v_session) = 0 OR length(v_session) > 100 THEN
        RAISE EXCEPTION '유효하지 않은 클라이언트 세션 식별자입니다.';
    END IF;

    SELECT aw.status, ex.visibility
    INTO v_artwork_status, v_exhibition_visibility
    FROM public.artworks aw
    JOIN public.exhibitions ex ON ex.id = aw.exhibition_id
    WHERE aw.id = target_artwork_id;

    IF v_artwork_status IS NULL THEN
        RAISE EXCEPTION '대상 작품이 존재하지 않습니다.';
    END IF;

    IF v_artwork_status != 'approved' OR v_exhibition_visibility != 'public' THEN
        RAISE EXCEPTION '공개 전시관의 승인된 작품에만 좋아요를 표시할 수 있습니다.';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.artwork_likes
        WHERE artwork_id = target_artwork_id AND session_id = v_session
    ) INTO v_liked_exists;

    IF v_liked_exists THEN
        DELETE FROM public.artwork_likes
        WHERE artwork_id = target_artwork_id AND session_id = v_session;
        v_action := 'unliked';
    ELSE
        INSERT INTO public.artwork_likes (artwork_id, session_id)
        VALUES (target_artwork_id, v_session);
        v_action := 'liked';
    END IF;

    SELECT count(*) INTO v_likes_count
    FROM public.artwork_likes
    WHERE artwork_id = target_artwork_id;

    RETURN json_build_object('action', v_action, 'likes', v_likes_count);
END;
$$;

REVOKE ALL ON FUNCTION public.toggle_artwork_like(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_artwork_like(UUID, TEXT) TO anon, authenticated;


-- =========================================================================
-- 11. Row Level Security 활성화
-- =========================================================================

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exhibitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exhibition_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exhibition_managers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.artworks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.artwork_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.artwork_likes ENABLE ROW LEVEL SECURITY;


-- -------------------------------------------------------------------------
-- 12. categories 정책
-- -------------------------------------------------------------------------
CREATE POLICY categories_select_all
    ON public.categories FOR SELECT TO public
    USING (true);

CREATE POLICY categories_admin_write
    ON public.categories FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

-- -------------------------------------------------------------------------
-- 13. profiles 정책
--     일반 사용자는 UPDATE 정책이 전혀 없어 role/manager_type을 포함한
--     어떤 필드도 스스로 변경할 수 없다. 변경은 admin만 가능하다.
-- -------------------------------------------------------------------------
CREATE POLICY profiles_select_self_or_admin
    ON public.profiles FOR SELECT TO authenticated
    USING (auth.uid() = id OR public.is_admin());

CREATE POLICY profiles_update_admin
    ON public.profiles FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

-- -------------------------------------------------------------------------
-- 14. exhibitions 정책
--     anon도 평가하는 SELECT 정책에는 is_admin()/manages_exhibition() 같은
--     authenticated 전용 헬퍼 함수를 호출하지 않는다. anon은 이 함수들의 실행
--     권한이 없어 정책 평가 중 permission denied가 발생하기 때문이다.
--     그래서 "공개 조건"과 "manager/admin 조건"을 별도 정책으로 분리하고,
--     후자는 TO authenticated로만 한정한다(정책은 OR로 합쳐진다).
-- -------------------------------------------------------------------------
CREATE POLICY exhibitions_select_public
    ON public.exhibitions FOR SELECT TO public
    USING (visibility = 'public');

CREATE POLICY exhibitions_select_manager
    ON public.exhibitions FOR SELECT TO authenticated
    USING (public.manages_exhibition(id));

CREATE POLICY exhibitions_select_admin
    ON public.exhibitions FOR SELECT TO authenticated
    USING (public.is_admin());

CREATE POLICY exhibitions_insert_admin
    ON public.exhibitions FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());

CREATE POLICY exhibitions_update_admin
    ON public.exhibitions FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

CREATE POLICY exhibitions_delete_admin
    ON public.exhibitions FOR DELETE TO authenticated
    USING (public.is_admin());

-- -------------------------------------------------------------------------
-- 15. exhibition_stats 정책
--     exhibitions와 동일한 이유로 anon용 공개 조건과 admin 전용 조건을 분리한다.
-- -------------------------------------------------------------------------
CREATE POLICY exhibition_stats_select_public
    ON public.exhibition_stats FOR SELECT TO public
    USING (
        EXISTS (
            SELECT 1 FROM public.exhibitions ex
            WHERE ex.id = exhibition_stats.exhibition_id
              AND ex.visibility = 'public'
              AND ex.is_demo = false
        )
    );

CREATE POLICY exhibition_stats_select_admin
    ON public.exhibition_stats FOR SELECT TO authenticated
    USING (public.is_admin());

CREATE POLICY exhibition_stats_insert_admin
    ON public.exhibition_stats FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());

CREATE POLICY exhibition_stats_update_admin
    ON public.exhibition_stats FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

CREATE POLICY exhibition_stats_delete_admin
    ON public.exhibition_stats FOR DELETE TO authenticated
    USING (public.is_admin());

-- -------------------------------------------------------------------------
-- 16. exhibition_managers 정책
-- -------------------------------------------------------------------------
CREATE POLICY exhibition_managers_select
    ON public.exhibition_managers FOR SELECT TO authenticated
    USING (profile_id = auth.uid() OR public.is_admin());

CREATE POLICY exhibition_managers_insert_admin
    ON public.exhibition_managers FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());

CREATE POLICY exhibition_managers_update_admin
    ON public.exhibition_managers FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

CREATE POLICY exhibition_managers_delete_admin
    ON public.exhibition_managers FOR DELETE TO authenticated
    USING (public.is_admin());

-- -------------------------------------------------------------------------
-- 17. artworks 정책
--     manager의 상태(status) 조작은 trg_enforce_artwork_status 트리거가
--     INSERT/UPDATE 시점에 강제로 pending 처리하므로 RLS와 이중으로 방지된다.
--     그와 별개로, 트리거가 어떤 이유로든 사라지거나 우회되는 경우를 대비해
--     manager 전용 INSERT/UPDATE WITH CHECK 자체에도 동일한 제약을 명시한다.
--     manager와 admin의 권한 폭이 근본적으로 다르므로(관리자는 상태를 자유롭게
--     다룰 수 있어야 함) 정책을 역할별로 분리하고 OR로 합친다.
-- -------------------------------------------------------------------------
CREATE POLICY artworks_select_public
    ON public.artworks FOR SELECT TO public
    USING (
        status = 'approved'
        AND EXISTS (
            SELECT 1 FROM public.exhibitions ex
            WHERE ex.id = artworks.exhibition_id AND ex.visibility = 'public'
        )
    );

CREATE POLICY artworks_select_manager
    ON public.artworks FOR SELECT TO authenticated
    USING (public.manages_exhibition(exhibition_id));

CREATE POLICY artworks_select_admin
    ON public.artworks FOR SELECT TO authenticated
    USING (public.is_admin());

-- manager는 자신이 담당하는 전시관에만, pending 상태·승인 이력 없음·
-- 본인 명의 제출로만 새 작품을 등록할 수 있다.
CREATE POLICY artworks_insert_manager
    ON public.artworks FOR INSERT TO authenticated
    WITH CHECK (
        public.manages_exhibition(exhibition_id)
        AND status = 'pending'
        AND approved_by IS NULL
        AND approved_at IS NULL
        AND submitted_by = auth.uid()
    );

CREATE POLICY artworks_insert_admin
    ON public.artworks FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());

-- manager는 현재 담당 중인 전시관의 작품만 수정할 수 있고(USING),
-- 수정 결과도 pending·승인 이력 없음·본인 제출 상태를 유지해야 하며(WITH CHECK),
-- exhibition_id를 바꾸려는 경우 그 새 전시관도 본인이 담당해야 한다.
CREATE POLICY artworks_update_manager
    ON public.artworks FOR UPDATE TO authenticated
    USING (public.manages_exhibition(exhibition_id))
    WITH CHECK (
        public.manages_exhibition(exhibition_id)
        AND status = 'pending'
        AND approved_by IS NULL
        AND approved_at IS NULL
        AND submitted_by = auth.uid()
    );

CREATE POLICY artworks_update_admin
    ON public.artworks FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

-- manager는 담당 전시관의 pending 또는 rejected 작품만 직접 삭제할 수 있다.
-- approved·hidden 작품 삭제는 admin만 가능하다.
CREATE POLICY artworks_delete_manager
    ON public.artworks FOR DELETE TO authenticated
    USING (
        public.manages_exhibition(exhibition_id)
        AND status IN ('pending', 'rejected')
    );

CREATE POLICY artworks_delete_admin
    ON public.artworks FOR DELETE TO authenticated
    USING (public.is_admin());

-- -------------------------------------------------------------------------
-- 18. artwork_comments 정책
--     exhibitions/artworks와 동일한 이유로 anon용 공개 조건과
--     manager/admin 조건을 별도 정책으로 분리한다.
-- -------------------------------------------------------------------------
CREATE POLICY artwork_comments_select_public
    ON public.artwork_comments FOR SELECT TO public
    USING (
        status = 'approved'
        AND EXISTS (
            SELECT 1 FROM public.artworks aw
            JOIN public.exhibitions ex ON ex.id = aw.exhibition_id
            WHERE aw.id = artwork_comments.artwork_id
              AND aw.status = 'approved'
              AND ex.visibility = 'public'
        )
    );

CREATE POLICY artwork_comments_select_manager
    ON public.artwork_comments FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.artworks aw
            WHERE aw.id = artwork_comments.artwork_id
              AND public.manages_exhibition(aw.exhibition_id)
        )
    );

CREATE POLICY artwork_comments_select_admin
    ON public.artwork_comments FOR SELECT TO authenticated
    USING (public.is_admin());

CREATE POLICY artwork_comments_insert_public
    ON public.artwork_comments FOR INSERT TO public
    WITH CHECK (status = 'pending');

CREATE POLICY artwork_comments_update_admin
    ON public.artwork_comments FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

-- -------------------------------------------------------------------------
-- 19. artwork_likes 정책
--     의도적으로 정책을 하나도 만들지 않는다. RLS는 켜져 있으므로
--     anon/authenticated의 직접 SELECT/INSERT/UPDATE/DELETE는 모두 기본 거부되고,
--     오직 SECURITY DEFINER인 toggle_artwork_like RPC(함수 소유자 권한으로 실행되어
--     RLS를 우회함)를 통해서만 데이터가 변경된다.
-- -------------------------------------------------------------------------


-- =========================================================================
-- 20. Data API 테이블 권한 (GRANT)
--     "Automatically expose new tables" 비활성화 + "Enable automatic RLS" 활성화
--     조합에서는 PostgREST(anon/authenticated)가 테이블에 접근하려면 RLS 정책과는
--     별개로 SQL GRANT 권한이 명시적으로 있어야 한다.
--     RLS는 "어떤 행을 볼 수 있는지"를, GRANT는 "어떤 명령 자체를 시도할 수
--     있는지"를 결정하는 서로 다른 계층이며 둘 다 통과해야 접근이 성립한다.
--     각 테이블에 REVOKE ALL로 먼저 초기화한 뒤, 위 RLS 정책이 실제로 사용하는
--     명령만 최소한으로 GRANT한다.
-- =========================================================================

GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- categories : 전체 조회는 공개, 쓰기는 categories_admin_write RLS로 admin만 허용
REVOKE ALL ON public.categories FROM anon, authenticated;
GRANT SELECT ON public.categories TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.categories TO authenticated;

-- profiles : 본인/admin만 조회, 수정은 profiles_update_admin RLS로 admin만 허용.
-- anon은 애초에 접근 대상이 아니므로 어떤 권한도 부여하지 않는다.
REVOKE ALL ON public.profiles FROM anon, authenticated;
GRANT SELECT, UPDATE ON public.profiles TO authenticated;

-- exhibitions : 공개 전시관은 anon도 조회 가능, 쓰기는 exhibitions_*_admin RLS로 admin만 허용
REVOKE ALL ON public.exhibitions FROM anon, authenticated;
GRANT SELECT ON public.exhibitions TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.exhibitions TO authenticated;

-- exhibition_stats : 공개·비데모 통계는 anon도 조회 가능, 쓰기는 admin만 허용
REVOKE ALL ON public.exhibition_stats FROM anon, authenticated;
GRANT SELECT ON public.exhibition_stats TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.exhibition_stats TO authenticated;

-- exhibition_managers : anon 접근 없음. 조회는 본인/admin, 쓰기는 admin만 RLS로 허용
REVOKE ALL ON public.exhibition_managers FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exhibition_managers TO authenticated;

-- artworks : 공개 전시관의 승인 작품은 anon도 조회 가능.
-- manager의 쓰기는 artworks_insert_manager/update_manager/delete_manager RLS로
-- 담당 전시관·상태 조건에 한정되고, admin은 별도의 artworks_*_admin 정책을 따른다.
REVOKE ALL ON public.artworks FROM anon, authenticated;
GRANT SELECT ON public.artworks TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.artworks TO authenticated;

-- artwork_comments : anon도 승인 댓글 조회 및 트리거·RLS 검증을 통과하는 댓글
-- 등록(INSERT)만 가능. 승인/반려 등 상태 변경(UPDATE)은 admin만 authenticated로 허용.
REVOKE ALL ON public.artwork_comments FROM anon, authenticated;
GRANT SELECT, INSERT ON public.artwork_comments TO anon, authenticated;
GRANT UPDATE ON public.artwork_comments TO authenticated;

-- artwork_likes : anon/authenticated에 어떤 테이블 권한도 부여하지 않는다.
-- toggle_artwork_like RPC(SECURITY DEFINER, 함수 소유자 권한으로 RLS와 GRANT를
-- 모두 우회)만 이 테이블을 변경할 수 있다.
REVOKE ALL ON public.artwork_likes FROM anon, authenticated;
