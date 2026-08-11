-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 09_require_operating_public_access.sql
-- 범위: anon(관람객) 공개 접근 조건을 강화하는 RLS 정책 7개 재생성과
--       댓글 검증 트리거 함수·좋아요 RPC 함수 2개 보완만 정의한다.
--
-- 목적:
--   지금까지 exhibitions_select_public 등 공개(anon) SELECT 정책과
--   storage.objects 공개 정책은 exhibitions.visibility='public'만 검사하고
--   exhibitions.operation_status는 검사하지 않았다. 그 결과 preparing/beta/
--   ended 상태이면서 visibility만 public인 전시관도 anon이 REST API를 직접
--   호출하면 전시관 행, 승인 작품 행, 이미지, PDF까지 전부 조회 가능했다
--   (앱의 getPublicExhibitions/getPublicArtworksForExhibition이 붙이는
--   operation_status='operating' 필터는 그 두 함수를 통한 호출에만 적용되는
--   클라이언트 쿼리일 뿐, RLS가 아니므로 다른 방식의 API 호출은 우회한다).
--
--   이 파일은 anon 공개 접근을 다음 세 조건을 모두 만족하는 경우로 제한한다.
--     - exhibition.visibility = 'public'
--     - exhibition.operation_status = 'operating'
--     - artwork.status = 'approved' (작품이 관련된 정책에 한함)
--
--   위 기준은 전시관(exhibitions), 전시관 통계(exhibition_stats), 작품
--   (artworks), 작품 댓글 조회(artwork_comments), 이미지(artwork-assets),
--   PDF(artwork-documents), 영상(artwork-video-assets) Storage에 모두
--   동일하게 적용한다. 댓글 작성을 검증하는 validate_and_sanitize_comment()
--   트리거 함수와 좋아요 토글 toggle_artwork_like() RPC도 같은 조건으로
--   보완해 조회뿐 아니라 댓글 작성·좋아요도 public+operating이 아닌
--   전시관에서는 더 이상 허용하지 않는다.
--
--   manager/admin 전용 SELECT/INSERT/UPDATE/DELETE 정책(예:
--   exhibitions_select_manager/admin, artworks_select_manager/admin,
--   storage_artwork_*_select_manager/admin, storage_artwork_*_insert_*,
--   storage_artwork_*_delete_*)은 is_admin()/manages_exhibition() 기준으로
--   operation_status와 무관하게 동작해야 하므로 이 파일에서 전혀 건드리지
--   않는다. artwork_comments_insert_public 정책도 status='pending'만
--   검사하는 원래 형태를 그대로 유지한다(visibility/operation_status
--   검사는 트리거의 책임이라는 기존 설계를 그대로 따름).
--
--   Storage INSERT/DELETE 정책도 전부 manager/admin 전용이라 이 gap과
--   무관하므로 이 파일에서 변경하지 않는다.
--
--   이 파일은 실제 데이터 UPDATE/DELETE를 전혀 포함하지 않는다. 사전에
--   read-only SELECT로 "visibility='public' AND operation_status<>'operating'
--   인 전시관 0건, 그런 전시관에 속한 approved 작품 0건"을 확인했으므로,
--   아래 정책 조건 강화만으로 기존에 정상적으로 공개 중인 public+operating
--   전시관/작품/이미지/PDF는 영향 없이 그대로 노출되고, 그 외의 경우(현재
--   존재하지 않는 것으로 확인된 public+비operating 조합)만 추가로 차단된다.
--
--   실행 전 검토 필요: 이 파일은 아직 실제 Supabase 프로젝트에 적용하지
--   않았다. 실행 전 반드시 아래 정책/함수 본문을 재검토하고, 파일 하단의
--   읽기 전용 검증 쿼리로 실행 후 상태를 확인할 것.
-- =========================================================================


-- =========================================================================
-- 1. 공개 SELECT 정책 7개 : DROP 후 동일한 이름으로 재생성
--    기존 정책이 반드시 존재한다는 전제이므로 DROP POLICY에 IF EXISTS를
--    쓰지 않는다. 정책 이름, 대상 테이블, FOR SELECT, TO 역할은 원본과
--    동일하게 유지하고 USING 조건에 operation_status='operating'만 추가한다.
-- =========================================================================

-- 1-A. exhibitions_select_public (원본: 02_security.sql)
DROP POLICY exhibitions_select_public ON public.exhibitions;

CREATE POLICY exhibitions_select_public
    ON public.exhibitions FOR SELECT TO public
    USING (
        visibility = 'public'
        AND operation_status = 'operating'
    );

-- 1-B. exhibition_stats_select_public (원본: 02_security.sql)
DROP POLICY exhibition_stats_select_public ON public.exhibition_stats;

CREATE POLICY exhibition_stats_select_public
    ON public.exhibition_stats FOR SELECT TO public
    USING (
        EXISTS (
            SELECT 1 FROM public.exhibitions ex
            WHERE ex.id = exhibition_stats.exhibition_id
              AND ex.visibility = 'public'
              AND ex.operation_status = 'operating'
              AND ex.is_demo = false
        )
    );

-- 1-C. artworks_select_public (원본: 02_security.sql)
DROP POLICY artworks_select_public ON public.artworks;

CREATE POLICY artworks_select_public
    ON public.artworks FOR SELECT TO public
    USING (
        status = 'approved'
        AND EXISTS (
            SELECT 1 FROM public.exhibitions ex
            WHERE ex.id = artworks.exhibition_id
              AND ex.visibility = 'public'
              AND ex.operation_status = 'operating'
        )
    );

-- 1-D. artwork_comments_select_public (원본: 02_security.sql)
DROP POLICY artwork_comments_select_public ON public.artwork_comments;

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
              AND ex.operation_status = 'operating'
        )
    );

-- 1-E. storage_artwork_assets_select_public (원본: 03_storage.sql)
DROP POLICY storage_artwork_assets_select_public ON storage.objects;

CREATE POLICY storage_artwork_assets_select_public
    ON storage.objects FOR SELECT TO public
    USING (
        bucket_id = 'artwork-assets'
        AND EXISTS (
            SELECT 1
            FROM public.artworks aw
            JOIN public.exhibitions ex ON ex.id = aw.exhibition_id
            WHERE (aw.thumbnail_url = storage.objects.name OR aw.media_url = storage.objects.name)
              AND aw.status = 'approved'
              AND ex.visibility = 'public'
              AND ex.operation_status = 'operating'
        )
    );

-- 1-F. storage_artwork_documents_select_public (원본: 07_add_document_video_storage.sql)
DROP POLICY storage_artwork_documents_select_public ON storage.objects;

CREATE POLICY storage_artwork_documents_select_public
    ON storage.objects FOR SELECT TO public
    USING (
        bucket_id = 'artwork-documents'
        AND EXISTS (
            SELECT 1
            FROM public.artworks aw
            JOIN public.exhibitions ex ON ex.id = aw.exhibition_id
            WHERE aw.media_url = storage.objects.name
              AND aw.status = 'approved'
              AND ex.visibility = 'public'
              AND ex.operation_status = 'operating'
        )
    );

-- 1-G. storage_artwork_video_assets_select_public (원본: 07_add_document_video_storage.sql)
DROP POLICY storage_artwork_video_assets_select_public ON storage.objects;

CREATE POLICY storage_artwork_video_assets_select_public
    ON storage.objects FOR SELECT TO public
    USING (
        bucket_id = 'artwork-video-assets'
        AND EXISTS (
            SELECT 1
            FROM public.artworks aw
            JOIN public.exhibitions ex ON ex.id = aw.exhibition_id
            WHERE aw.media_url = storage.objects.name
              AND aw.status = 'approved'
              AND ex.visibility = 'public'
              AND ex.operation_status = 'operating'
        )
    );


-- =========================================================================
-- 2. validate_and_sanitize_comment() 보완 (원본: 02_security.sql)
--    CREATE OR REPLACE이므로 기존 REVOKE/GRANT, 트리거 연결은 그대로
--    유지되며 이 파일에서 다시 선언하지 않는다. 원본의 변수 선언 순서,
--    입력 검증(빈 값/길이), 조회 대상, 각 조건의 개별 RAISE EXCEPTION
--    메시지, 원문 그대로 저장(sanitize 없음)하는 방식, status 강제,
--    SECURITY DEFINER, search_path는 전부 원본과 동일하게 유지하고,
--    exhibition.operation_status 조회·검사만 추가한다.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.validate_and_sanitize_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_content TEXT;
    v_artwork_status TEXT;
    v_exhibition_visibility TEXT;
    v_exhibition_operation_status TEXT;
    v_allow_comments BOOLEAN;
BEGIN
    v_content := trim(NEW.content);

    IF length(v_content) = 0 THEN
        RAISE EXCEPTION '댓글 내용은 비어 있을 수 없습니다.';
    END IF;

    IF length(v_content) > 500 THEN
        RAISE EXCEPTION '댓글은 500자를 초과할 수 없습니다.';
    END IF;

    SELECT aw.status, ex.visibility, ex.operation_status, ex.allow_comments
    INTO v_artwork_status, v_exhibition_visibility, v_exhibition_operation_status, v_allow_comments
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

    IF v_exhibition_operation_status != 'operating' THEN
        RAISE EXCEPTION '운영 중인 전시관의 작품에만 댓글을 등록할 수 있습니다.';
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


-- =========================================================================
-- 3. toggle_artwork_like(UUID, TEXT) 보완 (원본: 02_security.sql)
--    CREATE OR REPLACE이므로 기존 REVOKE/GRANT(anon, authenticated에 대한
--    EXECUTE)는 그대로 유지되며 이 파일에서 다시 선언하지 않는다. 파라미터
--    이름·타입(target_artwork_id UUID, client_session TEXT), RETURNS JSON,
--    세션 검증, 좋아요 토글/카운트 로직, 반환 형식(json_build_object),
--    SECURITY DEFINER, search_path는 전부 원본과 동일하게 유지하고,
--    exhibition.operation_status 조회와 기존 조건 검사에 operation_status
--    조건만 추가한다(원본이 status/visibility를 하나의 IF로 묶어 하나의
--    메시지로 처리하는 구조이므로, 동일한 구조에 조건만 추가해 새 메시지를
--    만들지 않는다).
-- =========================================================================

CREATE OR REPLACE FUNCTION public.toggle_artwork_like(target_artwork_id UUID, client_session TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_session TEXT;
    v_artwork_status TEXT;
    v_exhibition_visibility TEXT;
    v_exhibition_operation_status TEXT;
    v_liked_exists BOOLEAN;
    v_action TEXT;
    v_likes_count INTEGER;
BEGIN
    v_session := trim(coalesce(client_session, ''));

    IF length(v_session) = 0 OR length(v_session) > 100 THEN
        RAISE EXCEPTION '유효하지 않은 클라이언트 세션 식별자입니다.';
    END IF;

    SELECT aw.status, ex.visibility, ex.operation_status
    INTO v_artwork_status, v_exhibition_visibility, v_exhibition_operation_status
    FROM public.artworks aw
    JOIN public.exhibitions ex ON ex.id = aw.exhibition_id
    WHERE aw.id = target_artwork_id;

    IF v_artwork_status IS NULL THEN
        RAISE EXCEPTION '대상 작품이 존재하지 않습니다.';
    END IF;

    IF v_artwork_status != 'approved' OR v_exhibition_visibility != 'public' OR v_exhibition_operation_status != 'operating' THEN
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


-- =========================================================================
-- 4. 실행 후 참고용 읽기 전용 검증 쿼리 (전부 주석 처리, 자동 실행되지 않음)
--    아래 쿼리는 이 파일을 실제로 실행한 뒤 Supabase SQL Editor 등에서
--    수동으로 하나씩 실행해 결과를 확인하기 위한 것이며, 이 파일 자체는
--    어떤 SELECT도 자동으로 실행하지 않는다.
-- =========================================================================

-- 4-A. 정책 7개가 의도한 조건으로 재생성됐는지 확인
-- SELECT policyname, tablename, qual
-- FROM pg_policies
-- WHERE policyname IN (
--     'exhibitions_select_public',
--     'exhibition_stats_select_public',
--     'artworks_select_public',
--     'artwork_comments_select_public',
--     'storage_artwork_assets_select_public',
--     'storage_artwork_documents_select_public',
--     'storage_artwork_video_assets_select_public'
-- )
-- ORDER BY tablename, policyname;

-- 4-B. 함수 2개의 실제 정의 확인
-- SELECT pg_get_functiondef('public.validate_and_sanitize_comment()'::regprocedure);
-- SELECT pg_get_functiondef('public.toggle_artwork_like(uuid, text)'::regprocedure);

-- 4-C. public+operating 전시관이 여전히 조회되는지(관리자 세션으로 실행 시 참고용)
-- SELECT id, title, visibility, operation_status
-- FROM public.exhibitions
-- WHERE visibility = 'public' AND operation_status = 'operating';

-- 4-D. anon 세션(anon key)으로 실행 시 public이면서 operating이 아닌 행이
--      0건이어야 정상(수정 성공 확인). service_role 키로 실행하면 RLS를
--      우회하므로 반드시 anon 세션에서 실행할 것.
-- SELECT id, title, visibility, operation_status
-- FROM public.exhibitions
-- WHERE visibility = 'public' AND operation_status <> 'operating';
