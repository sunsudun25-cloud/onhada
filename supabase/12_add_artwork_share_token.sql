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
-- [재실행 가능성]
--   컬럼 추가는 ADD COLUMN IF NOT EXISTS, 함수는 CREATE OR REPLACE, 트리거는
--   DROP TRIGGER IF EXISTS 후 재생성, UNIQUE 제약은 pg_constraint를 먼저
--   확인하는 DO 블록으로 감싸 재실행해도 오류가 나지 않는다. 백필 UPDATE는
--   share_token IS NULL 조건이 있어 이미 채워진 행을 다시 건드리지 않으므로
--   재실행해도 추가로 할 일이 없으면 그대로 0건 처리된다. 기존 작품의
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
-- -------------------------------------------------------------------------
UPDATE public.artworks
SET share_token = public.generate_artwork_share_token()
WHERE share_token IS NULL;


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
