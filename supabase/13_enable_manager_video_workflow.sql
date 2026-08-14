-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 13_enable_manager_video_workflow.sql
-- 범위: 08_manager_own_artwork_workflow.sql이 만든 운영자 본인 작품
--       수정/자가승인/삭제 RPC를 영상(media_type='video', 직접 업로드/
--       외부 링크 두 방식 모두)까지 안전하게 확장한다. 기존 SQL 파일
--       (01~12)은 전혀 수정하지 않는다.
--
-- [기존 함수 재사용 여부]
--   approve_own_artwork(UUID)/delete_own_artwork(UUID)는 파라미터가 늘어날
--   필요가 없으므로(둘 다 artwork_id 하나만 받음) 기존 시그니처를 그대로
--   유지한 채 CREATE OR REPLACE로 media_type 제한만 완화한다 - 08 파일
--   자체는 수정하지 않고 이 파일이 나중에 같은 이름으로 교체한다
--   (09/10/11이 이미 쓴 것과 동일한 패턴).
--
--   update_own_artwork(...)는 외부 링크를 받으려면 external_url 파라미터가
--   반드시 필요한데, 기존 시그니처(9개 파라미터, media_type='image'|
--   'document' 전용 검증)를 그대로 확장하면 image/document 호출 경로까지
--   전부 다시 검토해야 하는 위험이 커진다. PostgREST(Supabase가 RPC 호출에
--   쓰는 REST 계층)는 같은 이름에 파라미터 목록이 다른 함수가 여러 개
--   있으면 어느 것을 호출할지 모호해질 수 있어(파라미터 오버로드 충돌),
--   같은 이름으로 새 시그니처를 추가하는 대신 완전히 새로운 이름
--   update_own_video_artwork(...)로 분리한다. 기존 update_own_artwork(...)는
--   이 파일에서 단 한 글자도 바꾸지 않으므로 이미지/문서 수정 경로는
--   회귀 위험이 없다.
--
-- [트리거 재사용]
--   enforce_artwork_status()(02/08)의 manager 자가승인 예외 분기는
--   media_type을 전혀 검사하지 않으므로(OLD.status/NEW.status/submitted_by/
--   exhibition_id/consent_confirmed/manages_exhibition만 검사) 이미 영상도
--   그대로 지원한다 - 수정하지 않는다.
--   enforce_artwork_share_token()(12)은 모든 UPDATE에서 무조건
--   NEW.share_token := OLD.share_token로 되돌리므로, 이 파일의 신규 RPC가
--   share_token을 SET하지 않아도(실제로 SET 절에 아예 포함하지 않는다)
--   기존 토큰이 항상 그대로 보존된다 - 수정하지 않는다.
--   enforce_video_artwork_paths()(10/11)는 media_type='video'인 모든
--   INSERT/UPDATE에서 media_url/thumbnail_url/external_url 구조를 다시
--   검증하는 최종 방어선으로 그대로 작동한다 - 수정하지 않는다.
--
-- [권한]
--   update_own_video_artwork(...)는 새 함수이므로 REVOKE ALL 후
--   authenticated에만 GRANT EXECUTE한다. approve_own_artwork/
--   delete_own_artwork는 시그니처가 바뀌지 않으므로 08 파일이 이미 설정한
--   REVOKE/GRANT(anon 없음, authenticated만 EXECUTE)가 그대로 유지되며 이
--   파일에서 다시 선언하지 않는다.
--
-- [재실행 가능성]
--   세 함수 모두 CREATE OR REPLACE FUNCTION만 사용하므로 여러 번 실행해도
--   오류 없이 안전하다(update_own_video_artwork도 이 파일에서 처음
--   정의되지만, 재실행 시 "함수가 이미 존재합니다" 오류 없이 같은 정의로
--   교체되도록 CREATE OR REPLACE를 쓴다). REVOKE/GRANT도 이미 있는 권한을
--   다시 회수/부여하는 것이라 재실행해도 오류가 나지 않는다. 이 파일은
--   DROP TABLE/COLUMN, 실제 데이터 UPDATE/DELETE 구문을 전혀 포함하지 않는다.
-- =========================================================================


-- =========================================================================
-- 1. public.approve_own_artwork(UUID) - media_type 제한을 video까지 확장.
--    시그니처(파라미터 목록)는 08 원본과 완전히 동일하므로 PostgREST 쪽
--    오버로드 문제가 없다. 그 외 로직(소유권/담당 재확인/pending 확인/
--    동의 확인/승인 정보 기록)은 원본과 한 글자도 다르지 않다.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.approve_own_artwork(artwork_id UUID)
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

    -- image/document에 video만 추가한다(08 원본은 IN ('image','document')).
    IF v_media_type NOT IN ('image', 'document', 'video') THEN
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


-- =========================================================================
-- 2. public.delete_own_artwork(UUID) - media_type 제한을 video까지 확장.
--    시그니처와 RETURNS TABLE 모양도 08 원본과 완전히 동일하다. 외부 링크
--    영상은 removed_media_url이 NULL로 반환되므로(원본 media_url 자체가
--    NULL), 호출부(js)가 "media_url이 있으면만 Storage 영상 삭제 시도"로
--    이미 안전하게 분기할 수 있어 이 함수의 반환 모양을 바꿀 필요가 없다.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.delete_own_artwork(artwork_id UUID)
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

    IF v_media_type NOT IN ('image', 'document', 'video') THEN
        RAISE EXCEPTION '이 작품 형식은 현재 운영자 직접 삭제를 지원하지 않습니다.';
    END IF;

    -- approved/hidden은 이 NOT IN 조건 하나로 명시적으로 차단된다(video도 동일하게 적용).
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


-- =========================================================================
-- 3. public.update_own_video_artwork(...) - 영상 전용 신규 수정 RPC.
--    update_own_artwork(...)와 소유권/담당자/hidden/상태 검증 골격은
--    동일하되, media_type은 항상 'video'로 고정하고 direct-upload/외부
--    링크 중 정확히 하나만 허용하는 검증은
--    enforce_video_artwork_paths()(10/11)의 판단 기준을 그대로 재사용한다.
--    share_token/submitted_by/exhibition_id는 파라미터로 받지도 않고 SET
--    절에도 넣지 않는다 - 어떤 입력으로도 변경할 수 없다.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.update_own_video_artwork(
    target_artwork_id UUID,
    p_title TEXT,
    p_artist_display_name TEXT,
    p_category_id TEXT,
    p_description TEXT,
    p_consent_confirmed BOOLEAN,
    p_media_url TEXT,
    p_thumbnail_url TEXT,
    p_external_url TEXT
)
RETURNS TABLE(previous_media_url TEXT, previous_thumbnail_url TEXT, previous_external_url TEXT)
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
    v_old_external_url TEXT;
    v_title TEXT;
    v_artist TEXT;
    v_description TEXT;
    v_path_prefix TEXT;
    v_host TEXT;
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
    SELECT a.exhibition_id, a.status, a.media_type, a.media_url, a.thumbnail_url, a.external_url
    INTO v_exhibition_id, v_status, v_old_media_type, v_old_media_url, v_old_thumbnail_url, v_old_external_url
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

    -- 이 RPC는 영상 전용이다. 기존 media_type이 video가 아닌 작품(다른
    -- 마이그레이션 시점에 등록됐거나 잘못된 artwork_id)은 명시적으로 거부한다.
    IF v_old_media_type <> 'video' THEN
        RAISE EXCEPTION '이 작품은 영상 수정 기능으로 처리할 수 없습니다.';
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

    -- 썸네일은 두 방식 모두 항상 필수이며, 항상 같은 전시관 폴더의 UUID
    -- 기반 이미지 경로여야 한다(10_enable_manager_video_artwork.sql과 동일 기준).
    v_path_prefix := v_exhibition_id::text
        || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

    IF p_thumbnail_url IS NULL OR p_thumbnail_url !~* ('^' || v_path_prefix || '\.(jpg|png|webp)$') THEN
        RAISE EXCEPTION '썸네일 경로 정보가 올바르지 않습니다.';
    END IF;

    -- 직접 업로드(p_media_url)와 외부 링크(p_external_url)는 정확히 하나만 허용한다.
    IF p_media_url IS NOT NULL AND p_external_url IS NOT NULL THEN
        RAISE EXCEPTION '영상은 직접 업로드 또는 외부 링크 중 하나만 등록할 수 있습니다.';
    END IF;

    IF p_media_url IS NULL AND p_external_url IS NULL THEN
        RAISE EXCEPTION '영상 파일 또는 외부 링크 중 하나는 반드시 등록해야 합니다.';
    END IF;

    IF p_media_url IS NOT NULL THEN
        -- 직접 업로드 영상 : 내부 UUID 기반 .mp4 경로만 허용, 다른 전시관 경로 차단.
        IF p_media_url !~* ('^' || v_path_prefix || '\.mp4$') THEN
            RAISE EXCEPTION '영상 경로 정보가 올바르지 않습니다.';
        END IF;

        IF p_media_url = p_thumbnail_url THEN
            RAISE EXCEPTION '영상과 썸네일 경로는 서로 달라야 합니다.';
        END IF;
    ELSE
        -- 외부 링크 영상 (이 시점에는 p_external_url IS NOT NULL이 보장됨).
        -- 11_enable_external_video_artwork.sql의 enforce_video_artwork_paths()와
        -- 동일한 판단 기준(구조만 검사, DNS/네트워크 조회 없음)을 그대로 재사용한다.
        IF length(p_external_url) > 2048 THEN
            RAISE EXCEPTION '외부 영상 링크 형식이 올바르지 않습니다.';
        END IF;

        IF p_external_url !~* '^https://[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?:/[^\s#]*)?\.mp4(?:\?[^\s#]*)?$' THEN
            RAISE EXCEPTION '외부 영상 링크 형식이 올바르지 않습니다.';
        END IF;

        v_host := (regexp_match(p_external_url, '^https://([^/?]+)', 'i'))[1];

        IF v_host IS NULL THEN
            RAISE EXCEPTION '외부 영상 링크 형식이 올바르지 않습니다.';
        END IF;

        v_host := lower(v_host);

        IF right(v_host, 1) = '.' THEN
            RAISE EXCEPTION '허용되지 않는 호스트입니다.';
        END IF;

        IF v_host = 'localhost' THEN
            RAISE EXCEPTION '허용되지 않는 호스트입니다.';
        END IF;

        IF v_host ~ '0x[0-9a-f]' THEN
            RAISE EXCEPTION '허용되지 않는 호스트입니다.';
        END IF;

        IF v_host ~ '^[0-9.]+$' THEN
            IF v_host !~ '^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$' THEN
                RAISE EXCEPTION '허용되지 않는 호스트입니다.';
            END IF;

            DECLARE
                v_octets TEXT[];
                v_oct_a INT;
                v_oct_b INT;
                v_oct_c INT;
                v_oct_d INT;
            BEGIN
                v_octets := regexp_split_to_array(v_host, '\.');
                v_oct_a := v_octets[1]::int;
                v_oct_b := v_octets[2]::int;
                v_oct_c := v_octets[3]::int;
                v_oct_d := v_octets[4]::int;

                IF v_oct_a > 255 OR v_oct_b > 255 OR v_oct_c > 255 OR v_oct_d > 255 THEN
                    RAISE EXCEPTION '허용되지 않는 호스트입니다.';
                END IF;

                IF v_oct_a = 10 OR v_oct_a = 127 OR v_oct_a = 0
                   OR (v_oct_a = 172 AND v_oct_b BETWEEN 16 AND 31)
                   OR (v_oct_a = 192 AND v_oct_b = 168)
                   OR (v_oct_a = 169 AND v_oct_b = 254) THEN
                    RAISE EXCEPTION '허용되지 않는 호스트입니다.';
                END IF;
            END;
        END IF;
    END IF;

    UPDATE public.artworks AS a
    SET title = v_title,
        artist_display_name = v_artist,
        category_id = p_category_id,
        description = NULLIF(v_description, ''),
        media_type = 'video',
        media_url = p_media_url,
        thumbnail_url = p_thumbnail_url,
        external_url = p_external_url,
        poem = NULL,
        consent_confirmed = true,
        status = 'pending',
        approved_by = NULL,
        approved_at = NULL,
        rejection_reason = NULL,
        updated_at = timezone('utc', now())
        -- exhibition_id, submitted_by, share_token은 파라미터로 받지도 않고
        -- SET 절에도 포함하지 않는다 - 어떤 입력으로도 변경할 수 없다
        -- (share_token은 12_add_artwork_share_token.sql의
        -- enforce_artwork_share_token() 트리거가 이 UPDATE에도 자동으로
        -- 적용되어 OLD 값으로 강제 복원한다).
    WHERE a.id = target_artwork_id AND a.submitted_by = auth.uid()
    RETURNING a.id INTO v_updated_id;

    IF v_updated_id IS NULL THEN
        RAISE EXCEPTION '작품 수정에 실패했습니다.';
    END IF;

    -- 보상 정리(Storage 파일 삭제)는 이 함수가 하지 않는다. 이전 경로만
    -- 반환하고, 실제 삭제는 호출부(js)에서 수행한다. 외부 링크였던 경우
    -- previous_external_url만 채워지고 previous_media_url은 NULL이므로,
    -- 호출부는 이 값을 Storage 삭제 대상으로 취급하지 않아야 한다(외부
    -- 원본 영상은 Storage에 없으므로 삭제 대상이 아니다).
    RETURN QUERY SELECT v_old_media_url, v_old_thumbnail_url, v_old_external_url;
END;
$$;

REVOKE ALL ON FUNCTION public.update_own_video_artwork(UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_own_video_artwork(UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_own_video_artwork(UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) TO authenticated;


-- =========================================================================
-- 실행 후 참고용 읽기 전용 검증 쿼리(전부 주석 처리, 자동 실행되지 않음)
-- =========================================================================

-- 세 함수 정의가 의도한 대로 교체/생성됐는지 확인
-- SELECT pg_get_functiondef('public.approve_own_artwork(uuid)'::regprocedure);
-- SELECT pg_get_functiondef('public.delete_own_artwork(uuid)'::regprocedure);
-- SELECT pg_get_functiondef('public.update_own_video_artwork(uuid,text,text,text,text,boolean,text,text,text)'::regprocedure);

-- update_own_artwork(...)가 이 파일 실행 이후에도 원본 그대로인지(이 파일이
-- 절대 건드리지 않았는지) 시그니처와 정의 확인
-- SELECT pg_get_functiondef('public.update_own_artwork(uuid,text,text,text,text,boolean,text,text,text)'::regprocedure);

-- update_own_artwork라는 이름으로 등록된 함수가 정확히 1개(오버로드 없음)인지 확인
-- SELECT proname, pg_get_function_identity_arguments(oid)
-- FROM pg_proc
-- WHERE proname IN ('update_own_artwork', 'update_own_video_artwork')
--   AND pronamespace = 'public'::regnamespace;

-- anon에게 신규 함수 EXECUTE 권한이 없는지 확인(0행이어야 정상)
-- SELECT grantee, privilege_type
-- FROM information_schema.routine_privileges
-- WHERE routine_name = 'update_own_video_artwork' AND grantee = 'anon';
