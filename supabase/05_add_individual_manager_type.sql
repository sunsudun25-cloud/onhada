-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 05_add_individual_manager_type.sql
-- 목적: profiles.manager_type에 개인 전시관 운영자 유형
--       'individual_creator'를 추가한다.
--
-- [중요] 01_schema.sql을 직접 확인한 결과, manager_type 관련 CHECK는
-- 하나가 아니라 두 개 따로 존재한다.
--
--   1. profiles_manager_type_check (컬럼 인라인 CHECK, Postgres 자동 명명)
--      CHECK (manager_type IN ('instructor', 'institution_staff'))
--      -> 허용 값 목록을 실제로 강제하는 제약조건은 바로 이것이다.
--
--   2. chk_profiles_manager_type (테이블 레벨 명명된 제약)
--      CHECK (
--          (role = 'manager' AND manager_type IS NOT NULL)
--          OR (role IN ('pending', 'admin') AND manager_type IS NULL)
--      )
--      -> 이 제약조건은 role에 따른 NULL 여부만 검사할 뿐 값 목록은
--         전혀 참조하지 않는다. 값이 무엇이든 role=manager일 때 NULL만
--         아니면 통과하므로, 새 값을 추가해도 이 제약조건은 그대로 두면 된다.
--
-- 따라서 이 파일은 값 목록을 실제로 강제하는 profiles_manager_type_check만
-- 수정한다. chk_profiles_manager_type은 값 목록과 무관하므로 수정하지 않는다.
-- =========================================================================

ALTER TABLE public.profiles
    DROP CONSTRAINT profiles_manager_type_check,
    ADD CONSTRAINT profiles_manager_type_check
    CHECK (
        manager_type IN (
            'instructor',
            'institution_staff',
            'individual_creator'
        )
    );
