-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 10_enable_manager_video_artwork.sql
-- 범위: media_type='video' 작품 INSERT/UPDATE 시 media_url(.mp4 경로)/
--       thumbnail_url(이미지 경로)/external_url 규칙을 DB 레벨에서도
--       강제하는 트리거 함수 1개와 그 트리거 1개만 정의한다.
-- 이 파일은 storage.buckets, storage.objects 정책, public.artworks 등
-- 다른 테이블/정책을 전혀 수정하지 않는다.
--
-- [배경]
--   02_security.sql의 artworks_insert_manager RLS(WITH CHECK)는
--   manages_exhibition(exhibition_id)/status='pending'/approved_by IS NULL/
--   approved_at IS NULL/submitted_by=auth.uid()만 검사하고, media_type이나
--   media_url/thumbnail_url의 경로 형식은 전혀 검사하지 않는다. 이는
--   image/document 작품도 마찬가지인 기존 구조이며(js/db-service.js의
--   createManagedUnifiedArtwork()가 지금까지 사실상 유일한 경로 검증
--   지점이었다), 이 파일은 image/document의 그 기존 동작을 전혀 바꾸지
--   않는다. video 작품만 DB 트리거로 한 단계 더 방어선을 추가한다.
--
-- [경로 규칙] 07_add_document_video_storage.sql과 동일하게
--   {exhibition_id}/{random_uuid}.mp4(영상) /
--   {exhibition_id}/{random_uuid}.(jpg|png|webp)(썸네일) 형식만 허용한다.
--   영상은 artwork-video-assets 버킷에, 썸네일은 artwork-assets 버킷에
--   저장되지만(각 버킷의 RLS는 07_add_document_video_storage.sql/
--   03_storage.sql이 이미 담당), 이 트리거는 artworks 테이블의 문자열
--   컬럼 값 형식만 검사하고 버킷 자체에는 접근하지 않는다.
--
-- [적용 범위]
--   NEW.media_type <> 'video'이면 이 트리거는 검사 없이 즉시 통과한다.
--   즉 image/document/text 등 다른 media_type의 INSERT/UPDATE는 이 파일
--   실행 전후로 동작이 전혀 달라지지 않는다.
--   media_type='video'로의 UPDATE 경로는 현재 앱에 존재하지 않지만
--   (update_own_artwork RPC는 image/document만 허용, authenticated의
--   UPDATE 직접 권한은 08_manager_own_artwork_workflow.sql에서 이미
--   회수됨), 향후 어떤 경로로든 video UPDATE가 생기더라도 동일한 규칙이
--   적용되도록 BEFORE INSERT OR UPDATE로 만든다.
--
-- [재실행/데이터 보존]
--   CREATE OR REPLACE FUNCTION + DROP TRIGGER IF EXISTS 후 CREATE TRIGGER
--   조합으로 여러 번 실행해도 안전하다. DROP TABLE/COLUMN, 실제 데이터
--   UPDATE/DELETE 구문은 전혀 포함하지 않는다.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.enforce_video_artwork_paths()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_path_prefix TEXT;
BEGIN
    IF NEW.media_type <> 'video' THEN
        RETURN NEW;
    END IF;

    IF NEW.exhibition_id IS NULL THEN
        RAISE EXCEPTION '전시관 정보가 올바르지 않습니다.';
    END IF;

    v_path_prefix := NEW.exhibition_id::text
        || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

    IF NEW.media_url IS NULL OR NEW.media_url !~* ('^' || v_path_prefix || '\.mp4$') THEN
        RAISE EXCEPTION '영상 경로 정보가 올바르지 않습니다.';
    END IF;

    IF NEW.thumbnail_url IS NULL OR NEW.thumbnail_url !~* ('^' || v_path_prefix || '\.(jpg|png|webp)$') THEN
        RAISE EXCEPTION '썸네일 경로 정보가 올바르지 않습니다.';
    END IF;

    IF NEW.media_url = NEW.thumbnail_url THEN
        RAISE EXCEPTION '영상과 썸네일 경로는 서로 달라야 합니다.';
    END IF;

    IF NEW.external_url IS NOT NULL THEN
        RAISE EXCEPTION '영상 작품에는 외부 링크를 등록할 수 없습니다.';
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_video_artwork_paths() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_video_artwork_paths() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_video_artwork_paths() FROM authenticated;

DROP TRIGGER IF EXISTS trg_enforce_video_artwork_paths ON public.artworks;

CREATE TRIGGER trg_enforce_video_artwork_paths
    BEFORE INSERT OR UPDATE ON public.artworks
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_video_artwork_paths();

-- =========================================================================
-- 실행 후 참고용 읽기 전용 검증 쿼리(전부 주석 처리, 자동 실행되지 않음)
-- =========================================================================

-- 트리거/함수가 정상 등록됐는지 확인
-- SELECT tgname, tgrelid::regclass, tgenabled
-- FROM pg_trigger
-- WHERE tgname = 'trg_enforce_video_artwork_paths';

-- SELECT pg_get_functiondef('public.enforce_video_artwork_paths()'::regprocedure);

-- image/document 작품이 이 트리거로 인해 하나도 막히지 않았는지(0건이어야
-- 정상 - 이 트리거는 media_type='video'가 아니면 즉시 통과하므로 애초에
-- 막을 수 없지만, 실행 직후 기존 데이터 기준으로 재확인용)
-- SELECT count(*) FROM public.artworks WHERE media_type IN ('image', 'document');
