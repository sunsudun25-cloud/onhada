-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 14_enable_exhibition_info_edit.sql
-- 범위: 배정된 강사(manager) 또는 관리자(admin)가 Supabase 기반(비외부)
--       전시관의 title/description/organization_name/tag/cover_image_path만
--       수정할 수 있는 RPC 1개만 정의한다. 기존 SQL 파일(01~13)은 전혀
--       수정하지 않는다.
--
-- [함수명]
--   update_managed_exhibition_info(...)로 명명한다. "own"이 아니라
--   "managed"를 쓴 이유는 이 함수가 강사 본인 소유 자원뿐 아니라 관리자가
--   모든 비외부 전시관을 대상으로도 호출할 수 있어, "own"이 암시하는
--   "본인 소유 한정" 의미가 관리자 사용 목적과 맞지 않기 때문이다.
--
-- [기존 함수 재사용]
--   manages_exhibition(UUID)(02_security.sql)를 그대로 재사용한다. 이
--   함수는 assignExhibitionManager()(js/db-service.js)가 is_external=true
--   전시관에는 애초에 강사를 배정하지 못하게 막아두었으므로, 강사 경로는
--   이 RPC 없이도 구조적으로 외부 전시관에 도달할 수 없다. 그럼에도 아래
--   6번에서 관리자 경로까지 포함해 is_external을 다시 한번 명시적으로
--   차단한다(관리자는 manages_exhibition() 검사를 거치지 않으므로).
--
-- [범위 제외]
--   is_external=true 전시관은 role과 무관하게 이 RPC에서 명시적으로
--   거부한다. 관리자가 외부 전시관을 수정해야 하는 경우는 기존 admin
--   직접 UPDATE 경로(exhibitions_update_admin RLS, 02_security.sql)를
--   그대로 쓰며, 이 RPC의 대상이 아니다. external_url 자체는 이 RPC의
--   파라미터/SET 절 어디에도 없으므로 이 함수를 통해서는 어떤 경로로도
--   변경 불가능하다.
--
-- [수정 금지 필드]
--   id, legacy_id, external_url, visibility, operation_status, slug,
--   exhibition_type, is_demo, is_external, allow_comments, start_date,
--   end_date, created_at은 파라미터로 받지 않고 SET 절에도 포함하지
--   않는다 - 어떤 입력으로도 변경할 수 없다. exhibition_managers(강사
--   배정)도 이 파일에서 전혀 건드리지 않는다(assignExhibitionManager/
--   unassignExhibitionManager가 계속 담당).
--
-- [권한]
--   REVOKE ALL 후 authenticated에만 GRANT EXECUTE. anon에는 권한을 주지
--   않는다. role 판정은 클라이언트를 신뢰하지 않고 이 함수 내부에서
--   profiles.role을 직접 다시 조회해 강제한다. 함수 소유자는 이 파일을
--   실행하는 세션(기존 함수들과 동일 관례)이며 별도로 소유자를 바꾸지
--   않는다.
--
-- [재실행 가능성]
--   CREATE OR REPLACE FUNCTION만 사용하므로 여러 번 실행해도 오류 없이
--   안전하다. REVOKE/GRANT도 이미 있는 권한을 다시 회수/부여하는 것이라
--   재실행해도 오류가 나지 않는다. DROP TABLE/COLUMN, 실제 데이터
--   UPDATE/DELETE 테스트 구문은 전혀 포함하지 않는다.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.update_managed_exhibition_info(
    target_exhibition_id UUID,
    p_title TEXT,
    p_description TEXT,
    p_organization_name TEXT,
    p_tag TEXT,
    p_cover_image_path TEXT
)
RETURNS TABLE(
    previous_cover_image_path TEXT,
    id UUID,
    title TEXT,
    description TEXT,
    organization_name TEXT,
    tag TEXT,
    cover_image_path TEXT,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_role TEXT;
    v_is_external BOOLEAN;
    v_old_cover_image_path TEXT;
    v_title TEXT;
    v_description TEXT;
    v_organization_name TEXT;
    v_tag TEXT;
    v_path_prefix TEXT;
    v_updated_id UUID;
BEGIN
    -- 1. 로그인 여부
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- 2. profiles.role을 DB에서 직접 조회(클라이언트 주장 신뢰하지 않음)
    SELECT p.role INTO v_role
    FROM public.profiles AS p
    WHERE p.id = auth.uid();

    -- 3. admin/manager가 아니면 거부
    IF v_role IS NULL OR v_role NOT IN ('admin', 'manager') THEN
        RAISE EXCEPTION '권한 거부: 전시관 정보를 수정할 수 없습니다.';
    END IF;

    -- 4. 대상 행을 잠가서 읽는다.
    SELECT ex.is_external, ex.cover_image_path
    INTO v_is_external, v_old_cover_image_path
    FROM public.exhibitions AS ex
    WHERE ex.id = target_exhibition_id
    FOR UPDATE;

    -- 5. 대상이 없으면 안전한 동일 메시지로 거부(존재 여부를 구분하는
    --    신호를 주지 않는다 - 아래 6/8번 거부와 동일한 문구를 쓰지는
    --    않지만, 각 사유별로 서로 다른 소유권 정보를 노출하지 않는다는
    --    원칙은 지킨다).
    IF NOT FOUND THEN
        RAISE EXCEPTION '전시관을 찾을 수 없습니다.';
    END IF;

    -- 6. 외부 연동 전시관은 role과 무관하게 이 기능의 대상이 아니다.
    IF v_is_external THEN
        RAISE EXCEPTION '외부 연동 전시관은 이 기능으로 수정할 수 없습니다.';
    END IF;

    -- 7~8. admin은 모든 비외부 전시관 통과. manager는 담당 전시관만 통과.
    -- 9. 다른 강사가 target_exhibition_id에 자신이 담당하지 않는 UUID를
    --    직접 넣어 호출해도 manages_exhibition()이 false를 반환해 여기서
    --    거부된다(버튼 우회 여부와 무관하게 DB가 최종 방어선).
    IF v_role = 'manager' THEN
        IF NOT public.manages_exhibition(target_exhibition_id) THEN
            RAISE EXCEPTION '담당하지 않는 전시관입니다.';
        END IF;
    END IF;
    -- v_role = 'admin'이면 추가 소유권 검사 없이 통과.

    -- 필드 검증 -----------------------------------------------------------
    v_title := trim(coalesce(p_title, ''));
    IF v_title = '' OR length(v_title) > 100 THEN
        RAISE EXCEPTION '전시관 이름을 100자 이내로 입력해 주세요.';
    END IF;

    v_description := trim(coalesce(p_description, ''));
    IF length(v_description) > 1000 THEN
        RAISE EXCEPTION '전시관 소개는 1000자를 초과할 수 없습니다.';
    END IF;

    v_organization_name := trim(coalesce(p_organization_name, ''));
    IF length(v_organization_name) > 100 THEN
        RAISE EXCEPTION '소속 기관명은 100자를 초과할 수 없습니다.';
    END IF;

    v_tag := trim(coalesce(p_tag, ''));
    IF length(v_tag) > 50 THEN
        RAISE EXCEPTION '전시 주제는 50자를 초과할 수 없습니다.';
    END IF;

    -- cover_image_path 검증 규칙(3단계). 이 RPC 배포 이전부터 exhibitions
    -- 테이블에 남아 있던 과거 형식 cover_image_path(예: 원본 파일명, 다른
    -- 폴더 구조 등 - 실제 Storage 객체가 없는 오래된 참조 포함)를 그대로
    -- 유지한 채 제목/소개 등 다른 필드만 고치는 정상적인 사용을 막지
    -- 않기 위해, "값을 바꾸지 않는 경우"와 "새 값으로 바꾸려는 경우"를
    -- 구분해서 검증한다.
    --   1) NULL이면 대표 이미지 제거로 항상 허용한다.
    --   2) NULL이 아니지만 기존 값(v_old_cover_image_path)과 완전히
    --      동일하면(=값을 바꾸지 않고 그대로 다시 보낸 "정보만 수정"
    --      케이스) 형식이 과거 형식이더라도 검증 없이 그대로 허용한다.
    --      비교는 IS DISTINCT FROM(NULL-안전 등호)의 부정, 즉 정확한
    --      case-sensitive 문자열 등호이며 trim/대소문자 변환 등으로 값
    --      자체를 바꾸지 않는다 - 정확히 같은 문자열일 때만 "변경 없음"
    --      으로 취급한다.
    --   3) 위 두 경우가 아니라면(=NULL이 아니면서 기존 값과 다른 새 값)
    --      이번에 새로 지정하려는 경로이므로 반드시 "이 전시관 자신의
    --      UUID 폴더 + 무작위 UUID 파일명" 형식이어야 한다. 슬래시가
    --      2개(경로 구분자 1개)를 초과하는 값, 폴더가 다른 전시관 UUID인
    --      값, 원본 파일명을 쓴 값, "..","//" 등 경로 탐색 시도는 이
    --      정규식 하나로 전부 거부된다(POSIX 정규식은 앵커(^...$)로 전체
    --      문자열을 강제하므로 부분 일치로 우회할 수 없다). 대소문자는
    --      의도적으로 소문자만 허용한다(대소문자 구분 없는 !~* 대신 !~
    --      사용) - 실제 경로는 항상 Postgres UUID::text 캐스팅과
    --      crypto.randomUUID()가 만드는 소문자로만 생성되므로, 대문자
    --      변형을 허용해도 실제로 존재하는 Storage 객체를 가리킬 수
    --      없다(대소문자를 구분하는 storage_exhibition_cover_select_public
    --      정책의 등호 비교 때문에 조용히 실패할 뿐 보안 우회는 아니다).
    --      다만 그런 값을 DB에 저장 자체를 허용할 이유가 없어 처음부터
    --      소문자만 통과시킨다.
    IF p_cover_image_path IS NOT NULL
       AND p_cover_image_path IS DISTINCT FROM v_old_cover_image_path THEN
        v_path_prefix := target_exhibition_id::text
            || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

        IF p_cover_image_path !~ ('^' || v_path_prefix || '\.(jpg|png|webp)$') THEN
            RAISE EXCEPTION '대표 이미지 경로 정보가 올바르지 않습니다.';
        END IF;
    END IF;

    UPDATE public.exhibitions AS ex
    SET title = v_title,
        description = NULLIF(v_description, ''),
        organization_name = NULLIF(v_organization_name, ''),
        tag = NULLIF(v_tag, ''),
        cover_image_path = p_cover_image_path,
        updated_at = timezone('utc', now())
        -- id, legacy_id, external_url, visibility, operation_status, slug,
        -- exhibition_type, is_demo, is_external, allow_comments,
        -- start_date, end_date는 파라미터로 받지도 않고 SET 절에도
        -- 포함하지 않는다 - 어떤 입력으로도 변경할 수 없다.
    WHERE ex.id = target_exhibition_id
    RETURNING ex.id INTO v_updated_id;

    IF v_updated_id IS NULL THEN
        RAISE EXCEPTION '전시관 정보 수정에 실패했습니다.';
    END IF;

    -- 실제 Storage 삭제는 이 함수가 하지 않는다. 이전 경로만 반환하고,
    -- 호출부(js)가 새 값과 다를 때만 보상 삭제를 수행한다. 수정된 값도
    -- 함께 반환해 호출부가 별도 재조회 없이 화면을 갱신할 수 있게 한다.
    RETURN QUERY
    SELECT v_old_cover_image_path,
           ex.id, ex.title, ex.description, ex.organization_name, ex.tag,
           ex.cover_image_path, ex.updated_at
    FROM public.exhibitions AS ex
    WHERE ex.id = target_exhibition_id;
END;
$$;

REVOKE ALL ON FUNCTION public.update_managed_exhibition_info(UUID, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_managed_exhibition_info(UUID, TEXT, TEXT, TEXT, TEXT, TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.update_managed_exhibition_info(UUID, TEXT, TEXT, TEXT, TEXT, TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.update_managed_exhibition_info(UUID, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;


-- =========================================================================
-- 실행 후 참고용 읽기 전용 검증 쿼리(전부 주석 처리, 자동 실행되지 않음)
-- =========================================================================

-- 함수 정의가 의도한 대로 생성됐는지 확인
-- SELECT pg_get_functiondef('public.update_managed_exhibition_info(uuid,text,text,text,text,text)'::regprocedure);

-- 함수가 정확히 1개(오버로드 없음)인지 확인
-- SELECT proname, pg_get_function_identity_arguments(oid)
-- FROM pg_proc
-- WHERE proname = 'update_managed_exhibition_info' AND pronamespace = 'public'::regnamespace;

-- anon에게 EXECUTE 권한이 없는지 확인(0행이어야 정상)
-- SELECT grantee, privilege_type
-- FROM information_schema.routine_privileges
-- WHERE routine_name = 'update_managed_exhibition_info' AND grantee = 'anon';

-- authenticated에만 EXECUTE 권한이 있는지 확인(1행이어야 정상)
-- SELECT grantee, privilege_type
-- FROM information_schema.routine_privileges
-- WHERE routine_name = 'update_managed_exhibition_info' AND grantee = 'authenticated';

-- SECURITY DEFINER와 search_path 확인
-- SELECT prosecdef, proconfig
-- FROM pg_proc
-- WHERE proname = 'update_managed_exhibition_info' AND pronamespace = 'public'::regnamespace;
