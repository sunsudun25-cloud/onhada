-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 99_rollback.sql
--
-- !! 경고 !!
-- 이 스크립트는 01_schema.sql ~ 04_seed_test.sql로 구성한 온하다 전용 신규
-- Supabase 프로젝트의 "초기 마이그레이션이 실패했을 때"만 사용하는 전체
-- 롤백 스크립트다. 실제 이용자 데이터, 실제 강사 계정, 실제 승인된 작품 등
-- 운영 데이터가 하나라도 들어간 뒤에는 절대 실행하지 마라. 그 시점부터는
-- 이 스크립트가 실제 데이터를 되돌릴 수 없이 삭제한다.
--
-- 이 스크립트가 삭제하지 않는 것 (보존 대상):
--   - auth.users 계정 (Supabase Auth 사용자 자체는 건드리지 않는다)
--   - index.html / app.html (수정하지 않는다)
--   - Git 이력 (아무 git 명령도 실행하지 않는다)
--   - 브라우저 localStorage (서버 측 스크립트이므로 애초에 접근하지 않는다)
--   - 외부 Lovable 전시관(on-sea-gallery.lovable.app 등 실제 서비스) 자체
--   - Storage의 artwork-assets 버킷과 그 안의 파일
--
-- Storage는 이 파일로 정리하지 않는다:
--   - storage.objects 안의 실제 파일을 SQL로 삭제하지 않는다
--   - storage.buckets에서 artwork-assets 버킷 행을 DELETE하지 않는다
--   - storage.objects 테이블 구조도 변경하지 않는다
--   - artwork-assets 파일/버킷을 비우거나 삭제해야 한다면 Supabase Dashboard의
--     Storage 메뉴 또는 Storage 관리 API를 이용해 별도로 수행할 것.
--
-- pgcrypto 확장은 삭제하지 않는다(다른 용도로 이미 쓰이고 있을 수 있으므로).
-- 이 파일이 만든 것이 아니라 01_schema.sql이 CREATE EXTENSION IF NOT EXISTS로
-- "있으면 그대로 둔다"는 전제로 만든 확장이기 때문이다.
--
-- 삭제 순서(아래 그대로 실행해야 한다):
--   1. 03_storage.sql이 만든 storage.objects 정책 7개를 실제 이름으로 DROP
--   2. auth.users의 on_auth_user_created 트리거를 DROP
--      (auth.users 테이블 자체는 남기고 트리거만 제거한다)
--   3. public 테이블을 외래키 역순으로 DROP
--      (테이블을 DROP하면 그 테이블에 속한 RLS 정책과 트리거는 자동으로 함께
--       사라진다. 그래서 trg_enforce_artwork_status나
--       trg_validate_and_sanitize_comment처럼 삭제 대상 테이블 위에 정의된
--       트리거는 별도로 DROP TRIGGER를 시도하지 않는다 - 부분 마이그레이션
--       상태에서 해당 테이블이 이미 없으면 "relation does not exist" 오류로
--       스크립트 전체가 멈추기 때문이다)
--   4. 02_security.sql이 만든 함수 9개를 정확한 시그니처로 DROP
--
-- DROP CASCADE는 어디에도 쓰지 않는다. 테이블 삭제 순서를 외래키 역순으로
-- 정확히 지켰기 때문에 CASCADE 없이도 각 DROP이 성립한다.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. storage.objects 정책 7개 삭제 (03_storage.sql의 실제 정책 이름)
--    public 테이블을 먼저 지우면 이 정책들의 USING/WITH CHECK 조건이 존재하지
--    않는 테이블(public.artworks 등)을 참조하게 되므로, 반드시 public 테이블
--    삭제보다 먼저 이 정책들을 제거한다.
-- -------------------------------------------------------------------------
DROP POLICY IF EXISTS storage_artwork_assets_select_public ON storage.objects;
DROP POLICY IF EXISTS storage_artwork_assets_select_manager ON storage.objects;
DROP POLICY IF EXISTS storage_artwork_assets_select_admin ON storage.objects;
DROP POLICY IF EXISTS storage_artwork_assets_insert_manager ON storage.objects;
DROP POLICY IF EXISTS storage_artwork_assets_insert_admin ON storage.objects;
DROP POLICY IF EXISTS storage_artwork_assets_delete_manager ON storage.objects;
DROP POLICY IF EXISTS storage_artwork_assets_delete_admin ON storage.objects;


-- -------------------------------------------------------------------------
-- 2. auth.users 트리거 삭제 (auth.users 테이블 자체와 계정은 그대로 둔다)
-- -------------------------------------------------------------------------
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;


-- -------------------------------------------------------------------------
-- 3. public 테이블을 외래키 역순으로 삭제
--    artwork_likes/artwork_comments -> artworks -> exhibition_stats/
--    exhibition_managers -> exhibitions -> profiles -> categories
-- -------------------------------------------------------------------------
DROP TABLE IF EXISTS public.artwork_likes;
DROP TABLE IF EXISTS public.artwork_comments;
DROP TABLE IF EXISTS public.artworks;
DROP TABLE IF EXISTS public.exhibition_stats;
DROP TABLE IF EXISTS public.exhibition_managers;
DROP TABLE IF EXISTS public.exhibitions;
DROP TABLE IF EXISTS public.profiles;
DROP TABLE IF EXISTS public.categories;


-- -------------------------------------------------------------------------
-- 4. 02_security.sql이 만든 함수 9개 삭제 (정확한 시그니처)
-- -------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.is_admin();
DROP FUNCTION IF EXISTS public.manages_exhibition(UUID);
DROP FUNCTION IF EXISTS public.handle_new_user();
DROP FUNCTION IF EXISTS public.enforce_artwork_status();
DROP FUNCTION IF EXISTS public.approve_artwork(UUID);
DROP FUNCTION IF EXISTS public.reject_artwork(UUID, TEXT);
DROP FUNCTION IF EXISTS public.hide_artwork(UUID);
DROP FUNCTION IF EXISTS public.validate_and_sanitize_comment();
DROP FUNCTION IF EXISTS public.toggle_artwork_like(UUID, TEXT);
