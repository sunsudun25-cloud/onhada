-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 15_add_exhibition_cover_storage.sql
-- 범위: exhibition-cover-assets 버킷 생성/설정과 그 버킷 전용
--       storage.objects RLS 정책 7개만 정의한다. 기존 버킷(artwork-assets/
--       artwork-documents/artwork-video-assets)과 그 정책은 이 파일에서
--       전혀 수정하지 않는다.
--
-- [왜 새 버킷인가]
--   artwork-assets의 select_public 정책은 "어떤 artworks 행의 thumbnail_url/
--   media_url과 정확히 일치"해야만 통과한다(03_storage.sql). 전시관 대표
--   이미지는 그 어떤 artworks 행에도 대응하지 않으므로, 그 정책 구조상
--   공개 방문자는 그 이미지를 영원히 읽을 수 없다. 기존 정책을 고쳐 이
--   경우를 통과시키는 것은 "작품 파일 접근 = artworks 테이블과의 소유·
--   승인 관계"라는 그 버킷의 보안 불변식을 흐리는 것이라, 07_add_document_
--   video_storage.sql이 artwork-video-assets를 완전히 새 버킷으로 추가한
--   것과 동일한 원칙으로 전용 버킷을 새로 만든다.
--
-- [경로 규칙] 업로드 경로는 반드시 {exhibition_id}/{random_uuid}.{ext} 형식이다.
--   {exhibition_id}는 대표 이미지가 속한 전시관 자신의 UUID여야 하며,
--   파일명에는 원본 파일명·개인정보를 절대 쓰지 않고 무작위 UUID만 쓴다.
--   (기존 artwork-assets/artwork-video-assets와 동일한 규칙.)
--
-- [DB 필드 사용 규칙]
--   exhibitions.cover_image_path에는 이 private 버킷의 object path만
--   저장한다. public URL이 아니므로 <img src="..."> 등에 그대로 넣어도
--   열리지 않는다 - 반드시 storage-service.js의 downloadExhibitionCoverImage()로
--   받은 Blob을 URL.createObjectURL()로 감싸서 표시해야 한다.
--
-- [재실행 가능성]
--   버킷은 INSERT ... ON CONFLICT (id) DO UPDATE로 보안 관련 컬럼(public/
--   file_size_limit/allowed_mime_types)만 매번 엄격한 값으로 되돌린다.
--   정책은 각 CREATE POLICY 전에 동일 이름으로 DROP POLICY IF EXISTS를
--   먼저 실행해, 여러 번 실행해도 "정책이 이미 존재합니다" 오류 없이
--   안전하다. DROP TABLE/COLUMN, 실제 데이터 UPDATE/DELETE 구문은 전혀
--   포함하지 않는다.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. exhibition-cover-assets 버킷 생성/설정
-- -------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'exhibition-cover-assets',
    'exhibition-cover-assets',
    false,
    5242880,
    ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE SET
    public = false,
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']::text[];


-- =========================================================================
-- 2. storage.objects SELECT 정책 (3개)
--    anon이 평가하는 정책에는 is_admin()/manages_exhibition()을 호출하지
--    않는다(anon은 실행 권한이 없어 permission denied가 난다). manager
--    조건도 03_storage.sql과 동일하게 exhibition_managers.exhibition_id를
--    ::text로 캐스팅해 폴더 문자열과 비교한다(업로드 경로 폴더 구간이
--    항상 유효한 UUID라는 보장이 이 비교 시점에는 없으므로, UUID를
--    TEXT로 바꾸는 안전한 방향만 사용한다).
-- =========================================================================

DROP POLICY IF EXISTS storage_exhibition_cover_select_public ON storage.objects;

-- anon/authenticated 공통: 공개(public)+운영 중(operating)인 비외부
-- 전시관의 "현재" cover_image_path와 정확히 일치하는 파일만 읽을 수
-- 있다. 이전에 교체되어 더는 어떤 전시관의 cover_image_path도 가리키지
-- 않는 잔여 파일은 이 정책으로 노출되지 않는다.
CREATE POLICY storage_exhibition_cover_select_public
    ON storage.objects FOR SELECT TO public
    USING (
        bucket_id = 'exhibition-cover-assets'
        AND EXISTS (
            SELECT 1
            FROM public.exhibitions ex
            WHERE ex.cover_image_path = storage.objects.name
              AND ex.visibility = 'public'
              AND ex.operation_status = 'operating'
              AND ex.is_external = false
        )
    );

DROP POLICY IF EXISTS storage_exhibition_cover_select_manager ON storage.objects;

-- authenticated manager : 자신이 담당하는 전시관 폴더(경로 첫 구간)의
-- 파일은 공개·운영 상태와 무관하게 읽을 수 있다(비공개·준비 중이어도
-- 본인이 올린 현재 이미지를 미리보기로 확인할 수 있어야 하므로).
CREATE POLICY storage_exhibition_cover_select_manager
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'exhibition-cover-assets'
        AND EXISTS (
            SELECT 1
            FROM public.exhibition_managers em
            JOIN public.profiles p ON p.id = em.profile_id
            WHERE p.id = auth.uid()
              AND p.role = 'manager'
              AND em.exhibition_id::text = split_part(storage.objects.name, '/', 1)
        )
    );

DROP POLICY IF EXISTS storage_exhibition_cover_select_admin ON storage.objects;

-- authenticated admin : exhibition-cover-assets 버킷 전체를 읽을 수 있다.
CREATE POLICY storage_exhibition_cover_select_admin
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'exhibition-cover-assets'
        AND public.is_admin()
    );


-- =========================================================================
-- 3. storage.objects INSERT 정책 (2개)
--    anon 업로드 정책은 만들지 않는다(직접 업로드 금지, 기본 거부).
--    경로 형식({폴더 UUID}/{파일 UUID}.jpg|png|webp)을 정책 자체에서도
--    검증해, 폴더 소유권만 맞으면 임의 파일명을 쓸 수 있는 여지를
--    없앤다(원본 파일명·경로 탐색 문자열은 이 정규식 자체가 통째로 거부).
--    대소문자는 의도적으로 소문자만 허용한다(~* 대신 ~) - 실제 경로는
--    항상 crypto.randomUUID()가 만드는 소문자로만 생성된다. manager
--    정책의 em.exhibition_id::text = split_part(name,'/',1) 비교는
--    이미 대소문자를 구분하므로 대문자 폴더는 그 조건에서도 별도로
--    걸러지지만, 형식 검증 자체도 소문자로 통일해 두 조건의 판단
--    기준이 서로 어긋나지 않게 한다.
-- =========================================================================

DROP POLICY IF EXISTS storage_exhibition_cover_insert_manager ON storage.objects;

-- authenticated manager : 담당 전시관 폴더에만, 정확한 경로 형식으로만
-- 업로드할 수 있다. 5MB 용량 제한과 MIME 허용 목록은 위 버킷 설정에서
-- 이미 적용된다.
CREATE POLICY storage_exhibition_cover_insert_manager
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'exhibition-cover-assets'
        AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
        AND EXISTS (
            SELECT 1
            FROM public.exhibition_managers em
            JOIN public.profiles p ON p.id = em.profile_id
            WHERE p.id = auth.uid()
              AND p.role = 'manager'
              AND em.exhibition_id::text = split_part(name, '/', 1)
        )
    );

DROP POLICY IF EXISTS storage_exhibition_cover_insert_admin ON storage.objects;

-- authenticated admin : exhibition-cover-assets 버킷 전체에, 정확한
-- 경로 형식으로만 업로드할 수 있다.
CREATE POLICY storage_exhibition_cover_insert_admin
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'exhibition-cover-assets'
        AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
        AND public.is_admin()
    );


-- =========================================================================
-- 4. storage.objects UPDATE 정책
--    의도적으로 만들지 않는다. 교체는 새 무작위 UUID로 새 파일을 INSERT한
--    뒤 exhibitions.cover_image_path를 그 새 경로로 UPDATE하고, 이전
--    파일은 별도 DELETE로 정리하는 방식만 사용한다(기존 3개 버킷과 동일
--    원칙). RLS 정책이 없으므로 storage.objects에 대한 UPDATE는
--    anon/authenticated 누구에게도 기본적으로 거부된다.
-- =========================================================================


-- =========================================================================
-- 5. storage.objects DELETE 정책 (2개)
-- =========================================================================

DROP POLICY IF EXISTS storage_exhibition_cover_delete_manager ON storage.objects;

-- authenticated manager : 담당 전시관 폴더의 파일만 삭제할 수 있다.
-- 대표 이미지는 작품과 달리 승인 절차가 없으므로(단순 전시관 메타데이터)
-- 상태 조건 없이 폴더 소유권만 확인한다.
CREATE POLICY storage_exhibition_cover_delete_manager
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'exhibition-cover-assets'
        AND EXISTS (
            SELECT 1
            FROM public.exhibition_managers em
            JOIN public.profiles p ON p.id = em.profile_id
            WHERE p.id = auth.uid()
              AND p.role = 'manager'
              AND em.exhibition_id::text = split_part(name, '/', 1)
        )
    );

DROP POLICY IF EXISTS storage_exhibition_cover_delete_admin ON storage.objects;

-- authenticated admin : exhibition-cover-assets 버킷 전체에서 삭제할 수 있다.
CREATE POLICY storage_exhibition_cover_delete_admin
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'exhibition-cover-assets'
        AND public.is_admin()
    );

-- =========================================================================
-- 정책 목록 (참고용, 총 7개)
--   storage_exhibition_cover_select_public
--   storage_exhibition_cover_select_manager
--   storage_exhibition_cover_select_admin
--   storage_exhibition_cover_insert_manager
--   storage_exhibition_cover_insert_admin
--   storage_exhibition_cover_delete_manager
--   storage_exhibition_cover_delete_admin
--   (UPDATE 정책 없음 - 의도적)
-- =========================================================================


-- =========================================================================
-- 실행 후 참고용 읽기 전용 검증 쿼리(전부 주석 처리, 자동 실행되지 않음)
-- =========================================================================

-- 버킷 설정 확인
-- SELECT id, public, file_size_limit, allowed_mime_types
-- FROM storage.buckets WHERE id = 'exhibition-cover-assets';

-- 정책 7개가 정확히 존재하는지 확인
-- SELECT policyname, cmd, roles
-- FROM pg_policies
-- WHERE schemaname = 'storage' AND tablename = 'objects'
--   AND policyname LIKE 'storage_exhibition_cover_%'
-- ORDER BY policyname;

-- 기존 3개 버킷 정책이 이 파일 실행 후에도 그대로인지(개수 변화 없는지) 확인
-- SELECT count(*) FROM pg_policies
-- WHERE schemaname = 'storage' AND tablename = 'objects'
--   AND policyname LIKE 'storage_artwork_%';
