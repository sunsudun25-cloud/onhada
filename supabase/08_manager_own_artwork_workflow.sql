-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 08_manager_own_artwork_workflow.sql
--
-- 목적: 운영자(manager)가 "본인이 등록한(submitted_by=auth.uid()) 작품"에
--       한해 직접 수정 / 자가 승인 / 영구 삭제할 수 있게 한다.
--
-- 핵심 보안 원칙(이 파일 전체를 관통하는 규칙):
--   - 다른 운영자가 등록한 작품은 같은 전시관 담당자라도 절대 수정·승인·
--     삭제할 수 없다(모든 신규 RPC가 submitted_by=auth.uid()를 내부에서
--     다시 검증하며, 호출자가 보낸 artwork_id만 믿지 않는다).
--   - 관리자(admin)가 숨김(hidden) 처리한 작품은 운영자가 절대 수정할 수
--     없다(수정 RPC가 명시적으로 차단, RLS도 이중으로 차단).
--   - approved/hidden 작품은 운영자가 삭제할 수 없다(pending/rejected만
--     삭제 가능, 삭제 RPC와 RLS 양쪽에서 이중으로 강제).
--   - 이 파일 실행 이후 public.artworks에 대한 UPDATE/DELETE는 authenticated
--     역할의 직접 Data API 호출로는 더 이상 불가능하다(GRANT 자체를 회수).
--     기존 admin 전용 RPC(approve_artwork/reject_artwork/hide_artwork)와
--     이 파일이 새로 만드는 manager 전용 RPC(update_own_artwork/
--     approve_own_artwork/delete_own_artwork)만 SECURITY DEFINER로 실행되어
--     GRANT 회수와 무관하게 계속 작동하며, 이 6개 RPC만이 유일한 쓰기
--     통로가 된다.
--   - 기존 admin의 승인·반려·숨김 RPC와 그 의미는 이 파일에서 절대 바꾸지
--     않는다. enforce_artwork_status()의 admin 분기는 원본과 완전히 동일한
--     상태로 그대로 옮겨 적었다.
--   - Storage(artwork-assets/artwork-documents/artwork-video-assets)의 실제
--     파일 삭제는 이 SQL 파일에서 전혀 수행하지 않는다. 각 RPC는 삭제/교체
--     대상이 된 이전 파일 경로만 반환하고, 실제 Storage 객체 삭제는 이후
--     js/storage-service.js의 removeManagedArtworkAsset()/
--     removeManagedArtworkDocument()를 호출하는 JS 레이어(보상 정리)에서
--     수행한다.
--
-- [중요] 이 파일은 사용자가 Supabase SQL Editor 등에서 직접 실행하기 전까지
-- 절대 자동으로 실행되지 않는다. 실행 전 반드시 내용을 검토하고, 가능하면
-- 실행 전 데이터베이스 백업(Supabase 프로젝트의 Point-in-Time Recovery 또는
-- 수동 백업)을 확인해 둘 것을 권장한다. 이 파일은 DROP TABLE, DROP COLUMN,
-- Storage 버킷/정책 변경을 전혀 포함하지 않으며, 실제 작품 데이터를
-- UPDATE/DELETE하는 테스트 구문도 포함하지 않는다(함수 본문 내부의 정상
-- UPDATE/DELETE 문 제외).
-- =========================================================================


-- =========================================================================
-- 1. enforce_artwork_status() 트리거 함수 교체
--    02_security.sql 원본의 admin 분기와 기존 ELSE 분기는 의미를 한 글자도
--    바꾸지 않았다. admin 분기 뒤에 "manager 본인 작품 자가 승인" 전용
--    ELSIF 분기 하나만 추가했다. 이 예외는 approve_own_artwork RPC가 이미
--    동일한 조건을 함수 내부에서 검증한 뒤에만 도달하는 UPDATE에 대해,
--    트리거 레벨에서 한 번 더 강제하는 이중 방어선이다(기존 admin 분기의
--    consent 이중 검사와 동일한 설계 원칙).
-- =========================================================================
CREATE OR REPLACE FUNCTION public.enforce_artwork_status()
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
    ELSIF TG_OP = 'UPDATE'
          AND OLD.status = 'pending'
          AND NEW.status = 'approved'
          AND OLD.submitted_by = auth.uid()
          AND NEW.submitted_by IS NOT DISTINCT FROM OLD.submitted_by
          AND NEW.exhibition_id IS NOT DISTINCT FROM OLD.exhibition_id
          AND NEW.consent_confirmed IS TRUE
          AND public.manages_exhibition(OLD.exhibition_id) THEN
        -- manager 본인 작품 자가 승인 전용 좁은 예외. 위 8개 조건을 전부
        -- 만족할 때만 approved 전환과 승인 정보 기록을 허용한다.
        NEW.approved_by := auth.uid();
        NEW.approved_at := timezone('utc', now());
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


-- =========================================================================
-- 2. public.update_own_artwork(...) : manager 본인 작품 수정 RPC
--    01_schema.sql 확인 결과 categories.id와 artworks.category_id는 둘 다
--    TEXT이므로 p_category_id도 TEXT로 선언한다. artworks에는 rejected_at
--    컬럼이 존재하지 않으므로(rejection_reason만 존재) 이 함수 어디에서도
--    rejected_at을 사용하지 않는다.
-- =========================================================================
CREATE FUNCTION public.update_own_artwork(
    target_artwork_id UUID,
    p_title TEXT,
    p_artist_display_name TEXT,
    p_category_id TEXT,
    p_description TEXT,
    p_consent_confirmed BOOLEAN,
    p_media_url TEXT,
    p_thumbnail_url TEXT,
    p_media_type TEXT
)
RETURNS TABLE(previous_media_url TEXT, previous_thumbnail_url TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_exhibition_id UUID;
    v_status TEXT;
    v_old_media_type TEXT;
    v_old_media_url TEXT;
    v_old_thumbnail_url TEXT;
    v_title TEXT;
    v_artist TEXT;
    v_description TEXT;
    v_path_prefix TEXT;
    v_updated_id UUID;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.profiles AS p
        WHERE p.id = auth.uid() AND p.role = 'manager'
    ) THEN
        RAISE EXCEPTION '권한 거부: 운영자만 자신의 작품을 수정할 수 있습니다.';
    END IF;

    -- 본인 소유(submitted_by=auth.uid()) 행만 잠가서 읽는다. 다른 운영자의
    -- 작품이면 이 시점에 이미 아무 행도 잠기지 않고 v_exhibition_id가 NULL로 남는다.
    SELECT a.exhibition_id, a.status, a.media_type, a.media_url, a.thumbnail_url
    INTO v_exhibition_id, v_status, v_old_media_type, v_old_media_url, v_old_thumbnail_url
    FROM public.artworks AS a
    WHERE a.id = target_artwork_id AND a.submitted_by = auth.uid()
    FOR UPDATE;

    IF v_exhibition_id IS NULL THEN
        RAISE EXCEPTION '본인이 등록한 작품만 수정할 수 있습니다.';
    END IF;

    -- 지금 이 순간에도 해당 전시관 담당 운영자인지 재확인(배정이 그 사이
    -- 해제됐을 수 있으므로 소유권 확인과 별개로 다시 검사한다).
    IF NOT public.manages_exhibition(v_exhibition_id) THEN
        RAISE EXCEPTION '담당하지 않는 전시관의 작품입니다.';
    END IF;

    -- hidden은 다른 어떤 상태 검사보다 먼저, 명시적으로 차단한다.
    IF v_status = 'hidden' THEN
        RAISE EXCEPTION '관리자가 숨김 처리한 작품은 운영자가 수정할 수 없습니다.';
    END IF;

    IF v_status NOT IN ('pending', 'rejected', 'approved') THEN
        RAISE EXCEPTION '수정할 수 없는 작품 상태입니다.';
    END IF;

    -- 기존 media_type이 image/document가 아니면(text/video/audio/mixed)
    -- 1차 범위 밖이므로 차단한다.
    IF v_old_media_type NOT IN ('image', 'document') THEN
        RAISE EXCEPTION '이 작품 형식은 현재 운영자 직접 수정을 지원하지 않습니다.';
    END IF;

    IF p_media_type IS NULL OR p_media_type NOT IN ('image', 'document') THEN
        RAISE EXCEPTION '이미지 또는 문서 형식만 등록할 수 있습니다.';
    END IF;

    v_title := trim(coalesce(p_title, ''));
    IF v_title = '' OR length(v_title) > 100 THEN
        RAISE EXCEPTION '작품명을 100자 이내로 입력해 주세요.';
    END IF;

    v_artist := trim(coalesce(p_artist_display_name, ''));
    IF v_artist = '' OR length(v_artist) > 50 THEN
        RAISE EXCEPTION '작가 표시명을 50자 이내로 입력해 주세요.';
    END IF;

    v_description := trim(coalesce(p_description, ''));
    IF length(v_description) > 500 THEN
        RAISE EXCEPTION '작품 설명은 500자를 초과할 수 없습니다.';
    END IF;

    IF p_category_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.categories AS c WHERE c.id = p_category_id
    ) THEN
        RAISE EXCEPTION '카테고리를 선택해 주세요.';
    END IF;

    -- SQL 3값 논리 방지: p_consent_confirmed가 NULL이면 IS DISTINCT FROM true는
    -- true로 평가되어(NULL은 true와 "다름") 반드시 이 분기로 들어와 차단된다.
    IF p_consent_confirmed IS DISTINCT FROM true THEN
        RAISE EXCEPTION '전시 동의 확인이 필요합니다.';
    END IF;

    -- media_path(=p_media_url) NULL을 정규식 비교보다 먼저 명시적으로 차단한다.
    -- 정규식 연산자(~*)는 피연산자가 NULL이면 결과도 NULL이 되어 IF 조건에서
    -- "거짓"과 동일하게 취급되므로, NULL이 그대로 통과해버리는 사고를 막는다.
    IF p_media_url IS NULL THEN
        RAISE EXCEPTION '작품 파일 경로 정보가 올바르지 않습니다.';
    END IF;

    v_path_prefix := v_exhibition_id::text
        || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

    IF p_media_type = 'image' THEN
        IF p_thumbnail_url IS NULL THEN
            RAISE EXCEPTION '이미지 경로 정보가 올바르지 않습니다.';
        END IF;
        IF p_thumbnail_url IS DISTINCT FROM p_media_url THEN
            RAISE EXCEPTION '이미지 경로 정보가 올바르지 않습니다.';
        END IF;
        IF p_media_url !~* ('^' || v_path_prefix || '\.(jpg|png|webp)$') THEN
            RAISE EXCEPTION '이미지 경로 정보가 올바르지 않습니다.';
        END IF;
    ELSE
        -- p_media_type = 'document'
        IF p_media_url ~* ('^' || v_path_prefix || '\.pdf$') THEN
            -- PDF 문서: thumbnail_url은 반드시 NULL
            IF p_thumbnail_url IS NOT NULL THEN
                RAISE EXCEPTION '문서 경로 정보가 올바르지 않습니다.';
            END IF;
        ELSIF p_media_url ~* ('^' || v_path_prefix || '\.(jpg|png|webp)$') THEN
            -- 문서형 이미지: image와 동일한 thumbnail_url 규칙
            IF p_thumbnail_url IS NULL THEN
                RAISE EXCEPTION '문서 경로 정보가 올바르지 않습니다.';
            END IF;
            IF p_thumbnail_url IS DISTINCT FROM p_media_url THEN
                RAISE EXCEPTION '문서 경로 정보가 올바르지 않습니다.';
            END IF;
        ELSE
            RAISE EXCEPTION '문서 경로 정보가 올바르지 않습니다.';
        END IF;
    END IF;

    UPDATE public.artworks AS a
    SET title = v_title,
        artist_display_name = v_artist,
        category_id = p_category_id,
        description = NULLIF(v_description, ''),
        media_type = p_media_type,
        media_url = p_media_url,
        thumbnail_url = p_thumbnail_url,
        external_url = NULL,
        poem = NULL,
        consent_confirmed = true,
        status = 'pending',
        approved_by = NULL,
        approved_at = NULL,
        rejection_reason = NULL,
        updated_at = timezone('utc', now())
        -- exhibition_id, submitted_by는 파라미터로 받지도 않고 SET 절에도
        -- 포함하지 않는다 - 어떤 입력으로도 변경할 수 없다.
    WHERE a.id = target_artwork_id AND a.submitted_by = auth.uid()
    RETURNING a.id INTO v_updated_id;

    IF v_updated_id IS NULL THEN
        RAISE EXCEPTION '작품 수정에 실패했습니다.';
    END IF;

    -- 보상 정리(Storage 파일 삭제)는 이 함수가 하지 않는다. 이전 경로만
    -- 반환하고, 실제 삭제는 호출부(js/storage-service.js)에서 수행한다.
    RETURN QUERY SELECT v_old_media_url, v_old_thumbnail_url;
END;
$$;

REVOKE ALL ON FUNCTION public.update_own_artwork(UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_own_artwork(UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_own_artwork(UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) TO authenticated;


-- =========================================================================
-- 3. public.approve_own_artwork(artwork_id UUID) : manager 본인 작품 자가 승인 RPC
-- =========================================================================
CREATE FUNCTION public.approve_own_artwork(artwork_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_exhibition_id UUID;
    v_status TEXT;
    v_media_type TEXT;
    v_consent_confirmed BOOLEAN;
    v_updated_id UUID;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.profiles AS p
        WHERE p.id = auth.uid() AND p.role = 'manager'
    ) THEN
        RAISE EXCEPTION '권한 거부: 운영자만 자신의 작품을 승인할 수 있습니다.';
    END IF;

    SELECT a.exhibition_id, a.status, a.media_type, a.consent_confirmed
    INTO v_exhibition_id, v_status, v_media_type, v_consent_confirmed
    FROM public.artworks AS a
    WHERE a.id = artwork_id AND a.submitted_by = auth.uid()
    FOR UPDATE;

    IF v_exhibition_id IS NULL THEN
        RAISE EXCEPTION '본인이 등록한 작품만 승인할 수 있습니다.';
    END IF;

    IF NOT public.manages_exhibition(v_exhibition_id) THEN
        RAISE EXCEPTION '담당하지 않는 전시관의 작품입니다.';
    END IF;

    IF v_media_type NOT IN ('image', 'document') THEN
        RAISE EXCEPTION '이 작품 형식은 현재 자가 승인을 지원하지 않습니다.';
    END IF;

    IF v_status <> 'pending' THEN
        RAISE EXCEPTION '승인 대기 상태의 작품만 승인할 수 있습니다.';
    END IF;

    IF v_consent_confirmed IS DISTINCT FROM true THEN
        RAISE EXCEPTION '개인정보 활용 동의가 완료되지 않아 승인할 수 없습니다.';
    END IF;

    UPDATE public.artworks AS a
    SET status = 'approved',
        approved_by = auth.uid(),
        approved_at = timezone('utc', now()),
        rejection_reason = NULL,
        updated_at = timezone('utc', now())
    WHERE a.id = artwork_id AND a.submitted_by = auth.uid()
    RETURNING a.id INTO v_updated_id;

    IF v_updated_id IS NULL THEN
        RAISE EXCEPTION '작품 승인에 실패했습니다.';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.approve_own_artwork(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_own_artwork(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.approve_own_artwork(UUID) TO authenticated;


-- =========================================================================
-- 4. public.delete_own_artwork(artwork_id UUID) : manager 본인 작품 영구 삭제 RPC
--    이 함수는 DB 행만 삭제한다. Storage 파일 삭제는 하지 않으며, 삭제
--    직전에 확보한 media_type/media_url/thumbnail_url을 반환해 호출부가
--    Storage 보상 정리에 사용하게 한다.
-- =========================================================================
CREATE FUNCTION public.delete_own_artwork(artwork_id UUID)
RETURNS TABLE(
    removed_media_type TEXT,
    removed_media_url TEXT,
    removed_thumbnail_url TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_exhibition_id UUID;
    v_status TEXT;
    v_media_type TEXT;
    v_media_url TEXT;
    v_thumbnail_url TEXT;
    v_deleted_id UUID;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.profiles AS p
        WHERE p.id = auth.uid() AND p.role = 'manager'
    ) THEN
        RAISE EXCEPTION '권한 거부: 운영자만 자신의 작품을 삭제할 수 있습니다.';
    END IF;

    SELECT a.exhibition_id, a.status, a.media_type, a.media_url, a.thumbnail_url
    INTO v_exhibition_id, v_status, v_media_type, v_media_url, v_thumbnail_url
    FROM public.artworks AS a
    WHERE a.id = artwork_id AND a.submitted_by = auth.uid()
    FOR UPDATE;

    IF v_exhibition_id IS NULL THEN
        RAISE EXCEPTION '본인이 등록한 작품만 삭제할 수 있습니다.';
    END IF;

    IF NOT public.manages_exhibition(v_exhibition_id) THEN
        RAISE EXCEPTION '담당하지 않는 전시관의 작품입니다.';
    END IF;

    IF v_media_type NOT IN ('image', 'document') THEN
        RAISE EXCEPTION '이 작품 형식은 현재 운영자 직접 삭제를 지원하지 않습니다.';
    END IF;

    -- approved/hidden은 이 NOT IN 조건 하나로 명시적으로 차단된다.
    IF v_status NOT IN ('pending', 'rejected') THEN
        RAISE EXCEPTION '승인되었거나 숨김 처리된 작품은 삭제할 수 없습니다.';
    END IF;

    DELETE FROM public.artworks AS a
    WHERE a.id = artwork_id AND a.submitted_by = auth.uid()
    RETURNING a.id INTO v_deleted_id;

    IF v_deleted_id IS NULL THEN
        RAISE EXCEPTION '작품 삭제에 실패했습니다.';
    END IF;

    RETURN QUERY SELECT v_media_type, v_media_url, v_thumbnail_url;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_own_artwork(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_own_artwork(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_own_artwork(UUID) TO authenticated;


-- =========================================================================
-- 5. 기존 manager RLS 정책 강화 (artworks_update_manager / artworks_delete_manager)
--    두 정책 모두 DROP 후 정확히 같은 이름으로 다시 만든다. admin 정책
--    (artworks_update_admin / artworks_delete_admin)은 이 파일에서 전혀
--    건드리지 않는다.
--
--    DROP POLICY는 의도적으로 IF EXISTS를 쓰지 않는다. 이 파일은
--    02_security.sql이 이미 실행되어 두 정책이 실제로 존재하는 마이그레이션
--    순서를 전제로 하므로, 만약 그 전제가 깨져 있다면(정책이 없다면) 조용히
--    건너뛰지 않고 DROP POLICY 자체가 오류로 즉시 실패해 문제를 드러내야 한다.
--
--    이 시점 이후 authenticated에는 UPDATE/DELETE GRANT 자체가 없어지므로
--    (아래 6번) 이 두 정책은 사실상 도달 불가능해지지만, 유지 비용이 없고
--    향후 실수로 GRANT가 복원되더라도 즉시 두 번째 방어선이 되도록 남겨둔다.
--    안전을 우선해 status 조건을 IN(...)과 <>('hidden') 양쪽으로 중복
--    기재했다.
-- =========================================================================

DROP POLICY artworks_update_manager ON public.artworks;

CREATE POLICY artworks_update_manager
    ON public.artworks FOR UPDATE TO authenticated
    USING (
        public.manages_exhibition(exhibition_id)
        AND submitted_by = auth.uid()
        AND status IN ('pending', 'rejected', 'approved')
        AND status <> 'hidden'
    )
    WITH CHECK (
        public.manages_exhibition(exhibition_id)
        AND submitted_by = auth.uid()
        AND status = 'pending'
        AND approved_by IS NULL
        AND approved_at IS NULL
    );

DROP POLICY artworks_delete_manager ON public.artworks;

CREATE POLICY artworks_delete_manager
    ON public.artworks FOR DELETE TO authenticated
    USING (
        public.manages_exhibition(exhibition_id)
        AND submitted_by = auth.uid()
        AND status IN ('pending', 'rejected')
    );


-- =========================================================================
-- 6. authenticated 역할의 artworks 직접 UPDATE/DELETE 권한 회수
--    SELECT/INSERT 권한은 그대로 유지한다. anon 권한은 이 파일에서 전혀
--    바꾸지 않는다(기존 03_storage.sql/02_security.sql의 anon 관련 GRANT는
--    원래도 artworks UPDATE/DELETE를 부여한 적이 없다).
--
--    이 REVOKE 이후 public.artworks에 대한 UPDATE/DELETE 통로는 다음
--    6개 SECURITY DEFINER RPC만 남는다:
--      admin  : approve_artwork(UUID), reject_artwork(UUID, TEXT), hide_artwork(UUID)
--      manager: update_own_artwork(...), approve_own_artwork(UUID), delete_own_artwork(UUID)
-- =========================================================================
REVOKE UPDATE, DELETE ON public.artworks FROM authenticated;
