-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 07_add_document_video_storage.sql
-- 범위: PDF 전용 private 버킷 artwork-documents, MP4 전용 private 버킷
--       artwork-video-assets 생성/설정과 storage.objects RLS 정책만 정의한다.
-- 기존 artwork-assets 버킷/정책, public.artworks 등 다른 테이블은 이 파일에서
-- 전혀 수정하지 않는다(03_storage.sql 정의를 그대로 둔다).
--
-- [경로 규칙] 03_storage.sql과 동일하게 업로드 경로는 반드시
--   {exhibition_id}/{random_uuid}.{ext} 형식이다.
--   예: 00000000-0000-0000-0000-000000000009/a1b2c3d4.pdf
--   파일명(경로의 두 번째 구간)에는 작가 실명, 나이, 기관명, 작품 제목, 이메일 등
--   개인정보를 포함하는 문자열을 절대 사용하지 않는다. 반드시 무작위 UUID만 쓴다.
--   artwork-documents는 pdf 확장자만, artwork-video-assets는 mp4 확장자만 허용한다.
--
-- [DB 필드 사용 규칙]
--   이 두 버킷에 올라간 object의 경로는 오직 public.artworks.media_url에만
--   저장한다. thumbnail_url은 이 두 버킷을 절대 참조하지 않는다.
--     - 영상(media_type='video') 파일 업로드 시 캡처하는 프레임 썸네일은
--       기존 artwork-assets 버킷에 이미지로 저장하고, artworks.thumbnail_url에는
--       그 artwork-assets 경로만 담는다.
--     - PDF(media_type='document')는 1차 버전에서 thumbnail_url을 NULL로 둔다.
--   YouTube/Vimeo 등 외부 영상 링크는 여전히 artworks.external_url에만 저장하고,
--   media_url/thumbnail_url에는 절대 넣지 않는다(03_storage.sql 규칙과 동일).
--
-- [Private 파일 다운로드 방식]
--   03_storage.sql과 동일하게 일반 관람객(브라우저)은 public URL을 쓰지 않는다.
--   프런트엔드는 Supabase JS 클라이언트의 Storage download API
--   (예: supabase.storage.from('artwork-documents').download(path),
--        supabase.storage.from('artwork-video-assets').download(path))를
--   anon key로 호출하고, 이 요청은 아래 SELECT 정책을 통과한 경우에만
--   Blob 데이터를 반환한다. signed URL 발급이나 service_role 키/secret은
--   브라우저(프런트엔드)에서 절대 사용하지 않는다.
--
-- [02_security.sql/03_storage.sql 대조 확인]
--   02_security.sql의 artworks_select_public 정책과 03_storage.sql의
--   storage_artwork_assets_select_public 정책을 직접 다시 확인한 결과, 두 정책
--   모두 status='approved'와 exhibitions.visibility='public'만 검사하고
--   operation_status는 검사하지 않는다. 이 파일의 신규 정책도 동일한 두 조건만
--   사용해 기존과 일관성을 유지한다(operation_status 조건을 새로 추가하지 않음).
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. artwork-documents / artwork-video-assets 버킷 생성/설정
--    03_storage.sql과 동일하게 ON CONFLICT 시에도 보안 관련 컬럼(public,
--    file_size_limit, allowed_mime_types)을 매번 아래 값으로 강제 재설정하여,
--    기존에 더 느슨한 설정이 남아 있더라도 이 파일 실행으로 항상 엄격한 값으로
--    되돌아가게 한다. 그 외 컬럼(owner, created_at 등)은 건드리지 않는다.
--    기존 artwork-assets 버킷 행은 이 파일에서 전혀 건드리지 않는다.
-- -------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'artwork-documents',
    'artwork-documents',
    false,
    20971520,
    ARRAY['application/pdf']::text[]
)
ON CONFLICT (id) DO UPDATE SET
    public = false,
    file_size_limit = 20971520,
    allowed_mime_types = ARRAY['application/pdf']::text[];

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'artwork-video-assets',
    'artwork-video-assets',
    false,
    52428800,
    ARRAY['video/mp4']::text[]
)
ON CONFLICT (id) DO UPDATE SET
    public = false,
    file_size_limit = 52428800,
    allowed_mime_types = ARRAY['video/mp4']::text[];


-- =========================================================================
-- 2. artwork-documents : storage.objects SELECT 정책
--    anon이 평가하는 정책에는 is_admin()/manages_exhibition()을 호출하지
--    않는다(anon은 실행 권한이 없어 permission denied가 난다).
--    manager 조건도 manages_exhibition(UUID)을 그대로 쓰지 않는다. 이 함수는
--    UUID 인자를 받는데, 업로드 경로의 폴더 구간은 사용자가 만든 임의의
--    문자열일 수 있어 그대로 ::uuid로 캐스팅하면 잘못된 형식일 때 예외가
--    발생해 조회 전체가 실패할 수 있다. 그래서 exhibition_managers.exhibition_id
--    쪽을 ::text로 캐스팅해 폴더 문자열과 안전하게 비교한다(03_storage.sql과
--    동일한 이유).
-- =========================================================================

-- anon/authenticated 공통: 승인된 작품이 속한 전시관이 공개(public)인 경우만
-- 그 작품의 media_url과 정확히 일치하는 파일을 읽을 수 있다. 이 버킷에는
-- thumbnail_url이 저장되지 않으므로 thumbnail_url은 비교하지 않는다.
-- pending/rejected/hidden 작품의 파일은 이 정책으로 절대 노출되지 않는다.
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
        )
    );

-- authenticated manager : 자신이 담당하는 전시관 폴더(경로 첫 구간)의 파일은
-- 작품 상태와 무관하게 읽을 수 있다.
CREATE POLICY storage_artwork_documents_select_manager
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'artwork-documents'
        AND EXISTS (
            SELECT 1
            FROM public.exhibition_managers em
            JOIN public.profiles p ON p.id = em.profile_id
            WHERE p.id = auth.uid()
              AND p.role = 'manager'
              AND em.exhibition_id::text = split_part(storage.objects.name, '/', 1)
        )
    );

-- authenticated admin : artwork-documents 버킷 전체를 읽을 수 있다.
CREATE POLICY storage_artwork_documents_select_admin
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'artwork-documents'
        AND public.is_admin()
    );


-- =========================================================================
-- 3. artwork-documents : storage.objects INSERT 정책
--    anon 업로드 정책은 만들지 않는다(직접 업로드 금지, 기본 거부).
-- =========================================================================

-- authenticated manager : 담당 전시관 폴더(경로 첫 구간)에만 업로드할 수 있다.
-- 20MB 용량 제한과 application/pdf MIME 허용 목록은 위 버킷 설정에서 이미 적용된다.
CREATE POLICY storage_artwork_documents_insert_manager
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'artwork-documents'
        AND EXISTS (
            SELECT 1
            FROM public.exhibition_managers em
            JOIN public.profiles p ON p.id = em.profile_id
            WHERE p.id = auth.uid()
              AND p.role = 'manager'
              AND em.exhibition_id::text = split_part(name, '/', 1)
        )
    );

-- authenticated admin : artwork-documents 버킷 전체에 업로드할 수 있다.
CREATE POLICY storage_artwork_documents_insert_admin
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'artwork-documents'
        AND public.is_admin()
    );


-- =========================================================================
-- 4. artwork-documents : storage.objects UPDATE 정책
--    03_storage.sql과 동일하게 의도적으로 UPDATE 정책을 하나도 만들지 않는다.
--    manager는 파일을 교체할 때 기존 object를 덮어쓰지 말고 새 무작위 UUID로
--    새 파일을 INSERT한 뒤, artworks.media_url을 그 새 경로로 UPDATE하는
--    방식을 사용해야 한다. admin도 특별한 사유가 없다면 같은 방식(새 파일
--    업로드 후 DB 경로 교체)을 사용하고, object 자체를 UPDATE하지 않는다.
--    RLS 정책이 없으므로 storage.objects에 대한 UPDATE는 anon/authenticated
--    누구에게도 기본적으로 거부된다.
-- =========================================================================


-- =========================================================================
-- 5. artwork-documents : storage.objects DELETE 정책
-- =========================================================================

-- authenticated manager : 담당 전시관 폴더의 파일 중,
--   - approved 또는 hidden 작품이 참조하는 파일은 삭제할 수 없다.
--   - pending/rejected 작품이 참조하는 파일은 삭제할 수 있다.
--   - 아직 어떤 artworks 행에도 연결되지 않은 파일(업로드 실패 후 잔여 파일 등)도
--     담당 폴더 안에 있다면 정리 목적으로 삭제할 수 있다.
--   이 버킷에는 thumbnail_url이 저장되지 않으므로 media_url만 검사한다.
CREATE POLICY storage_artwork_documents_delete_manager
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'artwork-documents'
        AND EXISTS (
            SELECT 1
            FROM public.exhibition_managers em
            JOIN public.profiles p ON p.id = em.profile_id
            WHERE p.id = auth.uid()
              AND p.role = 'manager'
              AND em.exhibition_id::text = split_part(name, '/', 1)
        )
        AND NOT EXISTS (
            SELECT 1 FROM public.artworks aw
            WHERE aw.media_url = name
              AND aw.status IN ('approved', 'hidden')
        )
    );

-- authenticated admin : artwork-documents 버킷 전체에서 삭제할 수 있다.
CREATE POLICY storage_artwork_documents_delete_admin
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'artwork-documents'
        AND public.is_admin()
    );


-- =========================================================================
-- 6. artwork-video-assets : storage.objects SELECT 정책
--    2번 섹션과 동일한 이유로 anon 평가 정책에는 is_admin()/manages_exhibition()을
--    호출하지 않고, manager 조건은 exhibition_managers.exhibition_id를 ::text로
--    캐스팅해 폴더 문자열과 비교한다.
-- =========================================================================

-- anon/authenticated 공통: 승인된 작품이 속한 전시관이 공개(public)인 경우만
-- 그 작품의 media_url과 정확히 일치하는 파일을 읽을 수 있다. 이 버킷에도
-- thumbnail_url은 저장되지 않으므로(캡처된 프레임은 artwork-assets에 저장)
-- thumbnail_url은 비교하지 않는다.
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
        )
    );

-- authenticated manager : 자신이 담당하는 전시관 폴더(경로 첫 구간)의 파일은
-- 작품 상태와 무관하게 읽을 수 있다.
CREATE POLICY storage_artwork_video_assets_select_manager
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'artwork-video-assets'
        AND EXISTS (
            SELECT 1
            FROM public.exhibition_managers em
            JOIN public.profiles p ON p.id = em.profile_id
            WHERE p.id = auth.uid()
              AND p.role = 'manager'
              AND em.exhibition_id::text = split_part(storage.objects.name, '/', 1)
        )
    );

-- authenticated admin : artwork-video-assets 버킷 전체를 읽을 수 있다.
CREATE POLICY storage_artwork_video_assets_select_admin
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'artwork-video-assets'
        AND public.is_admin()
    );


-- =========================================================================
-- 7. artwork-video-assets : storage.objects INSERT 정책
--    anon 업로드 정책은 만들지 않는다(직접 업로드 금지, 기본 거부).
-- =========================================================================

-- authenticated manager : 담당 전시관 폴더(경로 첫 구간)에만 업로드할 수 있다.
-- 50MB 용량 제한과 video/mp4 MIME 허용 목록은 위 버킷 설정에서 이미 적용된다.
CREATE POLICY storage_artwork_video_assets_insert_manager
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'artwork-video-assets'
        AND EXISTS (
            SELECT 1
            FROM public.exhibition_managers em
            JOIN public.profiles p ON p.id = em.profile_id
            WHERE p.id = auth.uid()
              AND p.role = 'manager'
              AND em.exhibition_id::text = split_part(name, '/', 1)
        )
    );

-- authenticated admin : artwork-video-assets 버킷 전체에 업로드할 수 있다.
CREATE POLICY storage_artwork_video_assets_insert_admin
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'artwork-video-assets'
        AND public.is_admin()
    );


-- =========================================================================
-- 8. artwork-video-assets : storage.objects UPDATE 정책
--    4번 섹션과 동일한 이유로 의도적으로 UPDATE 정책을 하나도 만들지 않는다.
--    영상을 교체할 때도 새 무작위 UUID로 새 파일을 INSERT한 뒤
--    artworks.media_url을 그 새 경로로 UPDATE하는 방식만 사용한다.
-- =========================================================================


-- =========================================================================
-- 9. artwork-video-assets : storage.objects DELETE 정책
-- =========================================================================

-- authenticated manager : 담당 전시관 폴더의 파일 중,
--   - approved 또는 hidden 작품이 참조하는 파일은 삭제할 수 없다.
--   - pending/rejected 작품이 참조하는 파일은 삭제할 수 있다.
--   - 아직 어떤 artworks 행에도 연결되지 않은 파일(업로드 실패 후 잔여 파일 등)도
--     담당 폴더 안에 있다면 정리 목적으로 삭제할 수 있다.
--   이 버킷에도 thumbnail_url은 저장되지 않으므로 media_url만 검사한다.
CREATE POLICY storage_artwork_video_assets_delete_manager
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'artwork-video-assets'
        AND EXISTS (
            SELECT 1
            FROM public.exhibition_managers em
            JOIN public.profiles p ON p.id = em.profile_id
            WHERE p.id = auth.uid()
              AND p.role = 'manager'
              AND em.exhibition_id::text = split_part(name, '/', 1)
        )
        AND NOT EXISTS (
            SELECT 1 FROM public.artworks aw
            WHERE aw.media_url = name
              AND aw.status IN ('approved', 'hidden')
        )
    );

-- authenticated admin : artwork-video-assets 버킷 전체에서 삭제할 수 있다.
CREATE POLICY storage_artwork_video_assets_delete_admin
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'artwork-video-assets'
        AND public.is_admin()
    );

-- =========================================================================
-- 정책 목록 (99_rollback.sql 작성 시 참고용, 총 14개 - 두 버킷 각 7개)
--   artwork-documents:
--     storage_artwork_documents_select_public
--     storage_artwork_documents_select_manager
--     storage_artwork_documents_select_admin
--     storage_artwork_documents_insert_manager
--     storage_artwork_documents_insert_admin
--     storage_artwork_documents_delete_manager
--     storage_artwork_documents_delete_admin
--   artwork-video-assets:
--     storage_artwork_video_assets_select_public
--     storage_artwork_video_assets_select_manager
--     storage_artwork_video_assets_select_admin
--     storage_artwork_video_assets_insert_manager
--     storage_artwork_video_assets_insert_admin
--     storage_artwork_video_assets_delete_manager
--     storage_artwork_video_assets_delete_admin
--   (두 버킷 모두 UPDATE 정책 없음 - 의도적)
--
-- 롤백 순서 주의: 위 정책들은 public.artworks, public.exhibitions,
-- public.exhibition_managers, public.profiles를 참조한다. 99_rollback.sql에서
-- 이 테이블들을 DROP하기 전에, 반드시 위 storage.objects 정책들을 먼저
-- DROP POLICY로 제거해야 한다. 순서가 뒤바뀌면 정책 본문이 존재하지 않는
-- 테이블을 참조하게 되어 DROP TABLE 시 참조 무결성/의존성 오류가 날 수 있다.
-- 기존 03_storage.sql의 artwork-assets 관련 7개 정책과 이 파일의 14개 정책은
-- 서로 독립적이므로 어느 순서로 롤백해도 무방하다.
-- =========================================================================
