-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 12_add_artwork_share_token.sql
-- 범위: public.artworks.share_token 컬럼 신설과 그 값을 안전하게 생성·
--       보호하는 함수·트리거만 정의한다. 기존 SQL 파일(01~11)은 전혀
--       수정하지 않는다.
--
-- [목적]
--   공개 작품마다 변하지 않는 ON하다 공유 주소(?work=share_token)를 만들기
--   위해, 작품 UUID와 별도인 예측 불가능한 무작위 토큰을 각 작품에 발급한다.
--   DB UUID를 URL에 직접 쓰지 않는 이유는 UUID는 생성 방식(gen_random_uuid)이
--   공개돼 있고 순차적으로 노출되면 다른 작품 UUID를 유추/열거하는 시도에
--   쓰일 수 있기 때문이며, share_token은 그 자체로 별도의 128비트 난수이므로
--   하나가 알려져도 다른 작품의 토큰을 유추할 단서가 되지 않는다.
--
-- [pgcrypto 확인]
--   01_schema.sql이 이미 `CREATE EXTENSION IF NOT EXISTS pgcrypto;`를
--   스키마 지정 없이 실행해 두었다. Supabase 프로젝트에 따라 이 확장의
--   함수(gen_random_bytes 등)가 실제로 `public` 스키마에 설치되는 경우와
--   Supabase가 기본 제공하는 `extensions` 스키마에 설치되는 경우가 둘 다
--   있을 수 있어(설치 시점의 세션 search_path에 따라 달라짐) 이 파일에서는
--   어느 한쪽으로 단정하지 않는다. 아래 generate_artwork_share_token()의
--   search_path에 public과 extensions을 모두 포함시켜, 존재하지 않는
--   스키마 이름이 search_path에 있어도 오류 없이 무시된다는 PostgreSQL의
--   동작을 활용해 두 경우 모두 안전하게 동작하도록 방어적으로 처리한다.
--
-- [토큰 형식]
--   gen_random_bytes(16)으로 만든 128비트(16바이트) 암호학적 난수를
--   16진수(encode(..., 'hex'))로 인코딩한 32자 소문자 영문(a-f)·숫자
--   문자열만 사용한다. 16진수 인코딩은 그 자체로 URL-safe하고 항상
--   소문자로 나오며 대소문자 혼동 문자(0/O, 1/l 등)가 섞일 여지가 없다.
--   제목·작가명·기관명·이메일·시간값·작품 UUID·순번 등 예측 가능하거나
--   개인정보와 연관될 수 있는 어떤 값도 재료로 사용하지 않는다.
--
-- [클라이언트 지정/변경 차단]
--   02_security.sql의 enforce_artwork_status()가 status/approved_by/
--   approved_at을 클라이언트 입력과 무관하게 강제로 재설정하는 것과 동일한
--   방식으로, 아래 enforce_artwork_share_token() 트리거가 INSERT 시에는
--   클라이언트가 payload에 무엇을 넣었든 항상 새로 생성한 값으로 덮어쓰고,
--   UPDATE 시에는 항상 기존 값(OLD.share_token)으로 되돌린다. 이 트리거는
--   이 백필(3번)이 끝나 모든 행이 NOT NULL을 만족한 뒤에 생성하므로, UPDATE
--   분기는 "OLD가 NULL일 수 있는 경우"를 별도로 처리할 필요가 없다.
--
-- [백필 중 상태 트리거 일시 비활성화 - 데이터 손상 방지]
--   08_manager_own_artwork_workflow.sql이 만든 trg_enforce_artwork_status
--   트리거(→ enforce_artwork_status())는 public.artworks에 대한 모든
--   INSERT/UPDATE에서 무조건 실행되며, UPDATE의 SET 절에 어떤 컬럼이
--   나열되어 있는지와 무관하게 매번 NEW 전체를 검사·재작성한다. Supabase
--   SQL Editor에서 이 파일을 실행하는 세션은 앱의 로그인 JWT 세션이
--   아니므로 auth.uid()가 NULL이고, 그 결과 enforce_artwork_status()
--   내부의 public.is_admin()도 false를 반환하며, manager 자가승인 전용
--   ELSIF 분기도 "OLD.submitted_by = auth.uid()" 비교가 NULL과의 비교라
--   항상 통과하지 못한다. 즉 아래 3번 백필 UPDATE를 트리거 비활성화 없이
--   그대로 실행하면 이 기존 트리거의 ELSE 분기(admin도 아니고 자가승인
--   조건도 아닌 경우)가 실행되어, share_token만 SET하려던 UPDATE임에도
--   28개 작품 전부의 status가 강제로 'pending'이 되고 approved_by/
--   approved_at이 NULL로 초기화된다 - 이미 승인되어 공개 전시 중인 26개
--   작품이 백필 직후 즉시 비공개 상태로 전환되는 실제 데이터 손상이다.
--   이를 막기 위해 아래 3번 백필을 단일 DO 블록으로 감싸고, 그 안에서만
--   trg_enforce_artwork_status 하나만 정확히 지정해 일시 비활성화한다.
--   session_replication_role은 세션의 모든 트리거·FK 검사를 끄므로 여기서
--   쓰지 않으며, SQL 10/11의 trg_enforce_video_artwork_paths나 이 파일이
--   뒤에서 새로 만드는 trg_enforce_artwork_share_token은 전혀 건드리지
--   않는다. ALTER TABLE ... DISABLE/ENABLE TRIGGER는 PostgreSQL에서
--   트랜잭션 범위의 DDL이며, DO 블록의 EXCEPTION 절은 그 BEGIN 블록
--   전체를 서브트랜잭션(SAVEPOINT)으로 감싼다 - 백필 도중 어떤 오류가
--   나더라도 EXCEPTION 핸들러 코드가 실행되기 전에 그 서브트랜잭션이
--   자동으로 DISABLE 이전 상태로 롤백되어 트리거는 이미 다시 활성
--   상태이며, 핸들러의 명시적 ENABLE 호출은 이 자동 복구를 전제로 한
--   이중 방어일 뿐이다(이미 활성화된 트리거에 ENABLE을 다시 실행해도
--   오류가 나지 않는다). 또한 DISABLE TRIGGER는 SHARE ROW EXCLUSIVE
--   잠금을 트랜잭션 종료까지 유지하므로, 이 DO 블록이 실행되는 짧은
--   구간 동안에는 다른 세션의 artworks INSERT/UPDATE/DELETE(ROW EXCLUSIVE
--   필요)가 전부 대기 상태로 차단되어, 트리거가 꺼져 있는 틈을 다른
--   요청이 파고들 여지가 없다. pg_trigger 조회로 트리거가 실제로 존재
--   하고 현재 활성 상태(tgenabled <> 'D')일 때만 DISABLE/ENABLE 쌍을
--   실행하므로, 이미 비활성 상태였던 경우(트리거 자체가 없는 경우
--   포함)는 그 상태를 그대로 두어 이 파일이 의도치 않게 트리거를 새로
--   켜거나 끄지 않는다.
--
-- [재실행 가능성]
--   컬럼 추가는 ADD COLUMN IF NOT EXISTS, 함수는 CREATE OR REPLACE, 트리거는
--   DROP TRIGGER IF EXISTS 후 재생성, UNIQUE 제약은 pg_constraint를 먼저
--   확인하는 DO 블록으로 감싸 재실행해도 오류가 나지 않는다. 백필 UPDATE는
--   share_token IS NULL 조건이 있어 이미 채워진 행을 다시 건드리지 않으므로
--   재실행해도 추가로 할 일이 없으면 그대로 0건 처리된다. 위 상태 트리거
--   일시 비활성화도 매번 pg_trigger를 다시 조회해 판단하므로 몇 번을
--   재실행해도 트리거가 비활성 상태로 누적되어 남지 않는다. 기존 작품의
--   내용·상태·경로·ID는 이 파일 어디에서도 변경·삭제하지 않는다.
-- =========================================================================


-- -------------------------------------------------------------------------
-- 1. 컬럼 추가 (아직 NOT NULL/UNIQUE 없음 - 백필 이후 아래에서 적용)
-- -------------------------------------------------------------------------
ALTER TABLE public.artworks
    ADD COLUMN IF NOT EXISTS share_token TEXT;


-- -------------------------------------------------------------------------
-- 2. 토큰 생성 함수. 충돌 시 안전하게 재생성(최대 10회 시도)하고, 그래도
--    남을 수 있는 극히 낮은 충돌 가능성은 4번의 UNIQUE 제약이 최종 방어한다.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_artwork_share_token()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
DECLARE
    v_token TEXT;
    v_attempt INT := 0;
BEGIN
    LOOP
        v_attempt := v_attempt + 1;
        v_token := encode(gen_random_bytes(16), 'hex');

        EXIT WHEN NOT EXISTS (
            SELECT 1 FROM public.artworks WHERE share_token = v_token
        );

        IF v_attempt >= 10 THEN
            RAISE EXCEPTION '공유 토큰을 생성하지 못했습니다.';
        END IF;
    END LOOP;

    RETURN v_token;
END;
$$;

REVOKE ALL ON FUNCTION public.generate_artwork_share_token() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_artwork_share_token() FROM anon;
REVOKE ALL ON FUNCTION public.generate_artwork_share_token() FROM authenticated;


-- -------------------------------------------------------------------------
-- 3. 기존 작품 백필 - share_token IS NULL인 행에만 발급한다. 이 시점에는
--    아직 6번의 트리거가 없으므로 이 UPDATE의 SET 값이 그대로 저장된다.
--    내용·상태·경로·ID는 이 UPDATE에서 전혀 건드리지 않는다.
--
--    02_security.sql/08_manager_own_artwork_workflow.sql이 이미 만들어 둔
--    trg_enforce_artwork_status는 share_token만 SET하는 이 UPDATE에도
--    무조건 실행되어, SQL Editor 세션(auth.uid() IS NULL)에서는 그 ELSE
--    분기가 실행되므로, 아래 UPDATE를 실행하는 구간에서만 그 트리거
--    하나를 정확히 지정해 일시 비활성화한다(위 헤더 "[백필 중 상태
--    트리거 일시 비활성화 - 데이터 손상 방지]" 참고). 다른 트리거나
--    session_replication_role은 전혀 건드리지 않는다.
-- -------------------------------------------------------------------------
DO $$
DECLARE
    v_should_restore BOOLEAN := false;
BEGIN
    -- 트리거가 실제로 존재하고 현재 활성 상태(tgenabled <> 'D')일 때만
    -- true가 된다. 트리거 자체가 없거나 이미 비활성 상태였다면 false로
    -- 남아 아래 DISABLE/ENABLE을 모두 건너뛰어 기존 상태를 그대로 둔다.
    SELECT (tgenabled <> 'D') INTO v_should_restore
    FROM pg_trigger
    WHERE tgname = 'trg_enforce_artwork_status'
      AND tgrelid = 'public.artworks'::regclass
      AND NOT tgisinternal;

    IF v_should_restore THEN
        ALTER TABLE public.artworks DISABLE TRIGGER trg_enforce_artwork_status;
    END IF;

    UPDATE public.artworks
    SET share_token = public.generate_artwork_share_token()
    WHERE share_token IS NULL;

    IF v_should_restore THEN
        ALTER TABLE public.artworks ENABLE TRIGGER trg_enforce_artwork_status;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- PL/pgSQL의 EXCEPTION 절은 이 BEGIN 블록 전체를 서브트랜잭션으로
        -- 감싸므로, 여기 도달한 시점에는 위에서 실행한 DISABLE TRIGGER가
        -- 이미 자동으로 롤백되어 트리거가 다시 활성 상태다. 아래 ENABLE은
        -- 그 자동 복구를 전제로 한 이중 방어이며, 이미 활성화된 트리거에
        -- 다시 실행해도 오류가 나지 않는다.
        IF v_should_restore THEN
            ALTER TABLE public.artworks ENABLE TRIGGER trg_enforce_artwork_status;
        END IF;
        RAISE;
END;
$$;


-- -------------------------------------------------------------------------
-- 4. 백필 완료 후 NOT NULL 적용(이미 NOT NULL이면 오류 없이 통과)
-- -------------------------------------------------------------------------
ALTER TABLE public.artworks
    ALTER COLUMN share_token SET NOT NULL;


-- -------------------------------------------------------------------------
-- 5. UNIQUE 제약 - 재실행 시 이미 있으면 건너뛴다(표준 ADD CONSTRAINT
--    구문은 IF NOT EXISTS를 지원하지 않아 pg_constraint를 직접 확인한다).
-- -------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_artworks_share_token'
          AND conrelid = 'public.artworks'::regclass
    ) THEN
        ALTER TABLE public.artworks
            ADD CONSTRAINT uq_artworks_share_token UNIQUE (share_token);
    END IF;
END;
$$;


-- -------------------------------------------------------------------------
-- 6. INSERT/UPDATE 시 클라이언트가 보낸 share_token 값을 항상 무시하고
--    서버가 강제하는 트리거. 02_security.sql의 enforce_artwork_status()와
--    동일한 BEFORE INSERT OR UPDATE 방식이며, 그 트리거와는 서로 다른
--    컬럼만 다루므로 실행 순서와 무관하게 함께 안전하게 동작한다.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_artwork_share_token()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- 강사/관리자가 payload에 share_token을 포함해 보내더라도 무시하고
        -- 항상 서버에서 새로 생성한다. 어떤 UI에서도 이 값을 직접 지정하거나
        -- 수정할 수 없다.
        NEW.share_token := public.generate_artwork_share_token();
    ELSIF TG_OP = 'UPDATE' THEN
        -- 생성된 뒤에는 절대 변경되지 않는다 - UPDATE payload에 다른 값이
        -- 오더라도 항상 기존 값으로 되돌린다.
        NEW.share_token := OLD.share_token;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_artwork_share_token() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_artwork_share_token() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_artwork_share_token() FROM authenticated;

DROP TRIGGER IF EXISTS trg_enforce_artwork_share_token ON public.artworks;

CREATE TRIGGER trg_enforce_artwork_share_token
    BEFORE INSERT OR UPDATE ON public.artworks
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_artwork_share_token();


-- =========================================================================
-- 실행 후 참고용 읽기 전용 검증 쿼리(전부 주석 처리, 자동 실행되지 않음)
-- =========================================================================

-- share_token이 NULL이거나 빈 값인 행이 0건인지 확인(NOT NULL이 이미
-- 강제하므로 정상 실행되면 이 쿼리 자체가 0행을 반환해야 한다)
-- SELECT id FROM public.artworks WHERE share_token IS NULL OR length(share_token) = 0;

-- share_token 중복이 없는지 확인(UNIQUE 제약이 이미 강제하므로 0행이어야 함)
-- SELECT share_token, count(*) FROM public.artworks GROUP BY share_token HAVING count(*) > 1;

-- 트리거가 정확히 1개만 있는지(중복 생성되지 않았는지) 확인
-- SELECT tgname, tgrelid::regclass, tgenabled
-- FROM pg_trigger
-- WHERE tgname = 'trg_enforce_artwork_share_token';

-- 클라이언트가 보낸 값이 실제로 무시되는지 수동 확인용(관리자 세션에서
-- 직접 실행 - share_token에 임의 값을 넣어도 실제 저장된 값은 서버 생성값이어야 함)
-- UPDATE public.artworks SET share_token = 'attacker-chosen-value' WHERE id = '00000000-0000-0000-0000-000000000000' RETURNING share_token;
