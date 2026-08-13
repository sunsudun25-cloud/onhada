-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 11_enable_external_video_artwork.sql
-- 범위: 10_enable_manager_video_artwork.sql이 만든
--       public.enforce_video_artwork_paths() 트리거 함수를
--       CREATE OR REPLACE로 확장해, media_type='video' 작품이
--       "직접 업로드" 또는 "외부 HTTPS MP4 링크" 중 정확히 하나의 방식만
--       사용하도록 검증 범위를 넓힌다. 이 파일은 그 함수 본문 하나만
--       바꾸며, 10 파일 자체는 전혀 수정하지 않는다.
--
-- [트리거 재사용 원리]
--   10_enable_manager_video_artwork.sql이 이미
--   `CREATE TRIGGER trg_enforce_video_artwork_paths ... EXECUTE FUNCTION
--   public.enforce_video_artwork_paths();`를 만들어 두었다. PostgreSQL의
--   트리거는 함수를 이름이 아니라 OID로 참조하고, CREATE OR REPLACE
--   FUNCTION은 같은 OID를 유지한 채 본문만 바꾸므로, 이 파일에서
--   트리거를 다시 만들 필요가 없다 - 함수 본문을 교체하는 즉시 기존
--   트리거가 새 로직으로 동작한다(09_require_operating_public_access.sql이
--   validate_and_sanitize_comment()/toggle_artwork_like()를 교체할 때와
--   동일한 방식).
--
-- [배경]
--   기존(10) 버전은 media_type='video'이면 media_url(.mp4 내부 경로)을
--   항상 필수로 요구하고 external_url은 항상 NULL이어야 한다고 강제했다.
--   이 파일은 그 규칙을 "직접 업로드(media_url 필수, external_url NULL)"
--   와 "외부 링크(media_url NULL, external_url 필수 + HTTPS MP4 직접
--   링크 형식)" 두 가지 중 정확히 하나만 허용하도록 확장한다.
--   thumbnail_url은 두 방식 모두에서 여전히 항상 필수다.
--
-- [적용 범위]
--   NEW.media_type <> 'video'이면 이 트리거는 검사 없이 즉시 통과한다.
--   image/document/text 등 다른 media_type의 INSERT/UPDATE는 이 파일
--   실행 전후로 동작이 전혀 달라지지 않는다. 기존 데이터를 UPDATE/DELETE
--   하는 구문도 포함하지 않는다.
--
-- [DB 레벨 검증의 한계 - 의도적 설계]
--   외부 URL의 DNS 조회나 실제 파일 콘텐츠(진짜 MP4인지, 실제로 접근
--   가능한지)는 이 트리거에서 네트워크 요청으로 확인하지 않는다.
--   PostgreSQL 트리거 함수 안에서 외부 네트워크 호출을 하는 것 자체가
--   위험하고(가용성·보안 문제), Supabase 표준 환경에서도 지원되지 않는다.
--   이 트리거는 오직 문자열 구조만 검사한다: https:// 시작, 사용자정보/
--   포트/fragment 없음, .mp4로 끝남, 호스트 끝 마침표·localhost·주요
--   사설/루프백 IPv4 대역(127.0.0.0/8, 0.0.0.0/8, 10.0.0.0/8,
--   172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16) 차단, 그리고 그 대역을
--   8진수·정수·16진수·축약 점십진 표기로 위장하려는 호스트(예:
--   "0177.0.0.1", "2130706433", "0x7f000001", "127.1") 자체를 실제
--   가리키는 주소를 계산하지 않고 통째로 차단(호스트가 숫자·마침표로만
--   이루어져 있는데 표준 4옥텟 점십진 표기가 아니면 무조건 거부).
--   호스트가 대괄호(`[`)나 콜론(`:`)을 포함하는 IPv6 리터럴(`[::1]`,
--   `[::ffff:127.0.0.1]` 등)은 도메인 문자 클래스 기반 구조 정규식 자체를
--   통과하지 못해 형식 오류로 이미 차단되므로 별도 처리가 필요 없다.
--   이는 js/db-service.js의 isValidExternalVideoUrl()·app.html의
--   onhadaValidateExternalVideoUrl()이 수행하는 것과 동일한 판단 기준을
--   DB 레벨에서 원본 문자열 기준으로 독립 재구현해 이중 방어선으로 삼는
--   것이다 - 정상 UI 흐름에서는 클라이언트가 먼저 차단하지만, 인증된
--   사용자가 클라이언트 코드를 우회해 DB에 직접 요청을 보내는 경우
--   이 트리거가 최종 방어선이 된다. 여전히 DNS 조회나 실제 네트워크
--   접근 없이 문자열만으로 판단하므로, 사설 IP를 가리키는 공인 도메인
--   (DNS 리바인딩)처럼 문자열만으로는 원천적으로 판별 불가능한 경우는
--   이 한계를 벗어나지 못한다.
--
-- [재실행/데이터 보존]
--   CREATE OR REPLACE FUNCTION만 사용하므로 여러 번 실행해도 안전하다.
--   DROP TRIGGER/CREATE TRIGGER를 다시 하지 않으므로 트리거가 중복
--   생성되거나 재실행이 실패할 가능성이 없다. DROP TABLE/COLUMN, 실제
--   데이터 UPDATE/DELETE 구문은 전혀 포함하지 않는다. REVOKE/GRANT도
--   10 파일이 이미 설정한 상태(PUBLIC/anon/authenticated 모두 EXECUTE
--   권한 없음 - 트리거 전용 함수이므로 직접 호출 권한이 필요 없다)를
--   그대로 유지하며 이 파일에서 다시 선언하지 않는다.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.enforce_video_artwork_paths()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_path_prefix TEXT;
    v_host TEXT;
    v_octets TEXT[];
    v_oct_a INT;
    v_oct_b INT;
    v_oct_c INT;
    v_oct_d INT;
BEGIN
    IF NEW.media_type <> 'video' THEN
        RETURN NEW;
    END IF;

    IF NEW.exhibition_id IS NULL THEN
        RAISE EXCEPTION '전시관 정보가 올바르지 않습니다.';
    END IF;

    v_path_prefix := NEW.exhibition_id::text
        || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

    -- 썸네일은 직접 업로드/외부 링크 방식과 무관하게 항상 필수이며, 항상
    -- 같은 전시관 폴더의 UUID 기반 이미지 경로여야 한다.
    IF NEW.thumbnail_url IS NULL OR NEW.thumbnail_url !~* ('^' || v_path_prefix || '\.(jpg|png|webp)$') THEN
        RAISE EXCEPTION '썸네일 경로 정보가 올바르지 않습니다.';
    END IF;

    -- 직접 업로드(media_url)와 외부 링크(external_url)는 정확히 하나만 허용한다.
    IF NEW.media_url IS NOT NULL AND NEW.external_url IS NOT NULL THEN
        RAISE EXCEPTION '영상은 직접 업로드 또는 외부 링크 중 하나만 등록할 수 있습니다.';
    END IF;

    IF NEW.media_url IS NULL AND NEW.external_url IS NULL THEN
        RAISE EXCEPTION '영상 파일 또는 외부 링크 중 하나는 반드시 등록해야 합니다.';
    END IF;

    IF NEW.media_url IS NOT NULL THEN
        -- 직접 업로드 영상 : 내부 UUID 기반 .mp4 경로만 허용.
        IF NEW.media_url !~* ('^' || v_path_prefix || '\.mp4$') THEN
            RAISE EXCEPTION '영상 경로 정보가 올바르지 않습니다.';
        END IF;

        IF NEW.media_url = NEW.thumbnail_url THEN
            RAISE EXCEPTION '영상과 썸네일 경로는 서로 달라야 합니다.';
        END IF;
    ELSE
        -- 외부 링크 영상 (이 시점에는 NEW.external_url IS NOT NULL이 보장됨).
        IF length(NEW.external_url) > 2048 THEN
            RAISE EXCEPTION '외부 영상 링크 형식이 올바르지 않습니다.';
        END IF;

        -- https:// + 호스트(사용자정보/포트 없음) + 임의 경로 + .mp4로 끝남
        -- + 선택적 query string. fragment(#)는 문자 클래스에서 제외해
        -- 구조적으로 차단한다.
        IF NEW.external_url !~* '^https://[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?:/[^\s#]*)?\.mp4(?:\?[^\s#]*)?$' THEN
            RAISE EXCEPTION '외부 영상 링크 형식이 올바르지 않습니다.';
        END IF;

        v_host := (regexp_match(NEW.external_url, '^https://([^/?]+)', 'i'))[1];

        IF v_host IS NULL THEN
            RAISE EXCEPTION '외부 영상 링크 형식이 올바르지 않습니다.';
        END IF;

        v_host := lower(v_host);

        -- 끝에 마침표가 붙은 호스트(FQDN 루트 표기, 예: "localhost.")는
        -- 마침표를 지우고 다시 검사하지 않고 그 자체로 차단한다 - 지운 뒤
        -- 검사하면 "localhost."가 "localhost"와 다른 문자열이라는 이유로
        -- 아래 리터럴 차단을 우회하게 된다.
        IF right(v_host, 1) = '.' THEN
            RAISE EXCEPTION '허용되지 않는 호스트입니다.';
        END IF;

        IF v_host = 'localhost' THEN
            RAISE EXCEPTION '허용되지 않는 호스트입니다.';
        END IF;

        -- 16진수 표기(예: "0x7f000001", "0x7f.0.0.1")는 IP 위장 목적으로만
        -- 쓰이므로 실제 목적지를 계산하지 않고 그 자체로 차단한다.
        IF v_host ~ '0x[0-9a-f]' THEN
            RAISE EXCEPTION '허용되지 않는 호스트입니다.';
        END IF;

        -- 호스트가 숫자와 마침표로만 구성되어 있으면(문자가 하나도 없으면)
        -- IP 주소를 표기하려는 시도로 간주한다. 이 경우 "옥텟 4개, 각
        -- 옥텟에 불필요한 선행 0 없음"의 표준 점십진 표기만 허용하고,
        -- 그 외의 모든 숫자 전용 표기(정수 표기, 8진수로 해석될 수 있는
        -- 선행 0 표기, 옥텟 개수가 4개가 아닌 축약 표기 등)는 실제로
        -- 무엇을 가리키는지 계산하지 않고 통째로 차단한다. 문자가 섞인
        -- 일반 도메인(예: "video2026.example.com", "172video.example.com")은
        -- 이 분기에 들어오지 않으므로 영향받지 않는다.
        IF v_host ~ '^[0-9.]+$' THEN
            IF v_host !~ '^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$' THEN
                RAISE EXCEPTION '허용되지 않는 호스트입니다.';
            END IF;

            v_octets := regexp_split_to_array(v_host, '\.');
            v_oct_a := v_octets[1]::int;
            v_oct_b := v_octets[2]::int;
            v_oct_c := v_octets[3]::int;
            v_oct_d := v_octets[4]::int;

            IF v_oct_a > 255 OR v_oct_b > 255 OR v_oct_c > 255 OR v_oct_d > 255 THEN
                RAISE EXCEPTION '허용되지 않는 호스트입니다.';
            END IF;

            -- 주요 사설/루프백/미지정 IPv4 대역(127.0.0.0/8, 0.0.0.0/8,
            -- 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16)을
            -- 차단한다. 그 외의 표준 점십진 표기 공인 IP(예: 8.8.8.8)는
            -- 그대로 허용한다.
            IF v_oct_a = 10 OR v_oct_a = 127 OR v_oct_a = 0
               OR (v_oct_a = 172 AND v_oct_b BETWEEN 16 AND 31)
               OR (v_oct_a = 192 AND v_oct_b = 168)
               OR (v_oct_a = 169 AND v_oct_b = 254) THEN
                RAISE EXCEPTION '허용되지 않는 호스트입니다.';
            END IF;
        END IF;

        -- IPv6 리터럴(예: "[::1]", "[::ffff:127.0.0.1]")은 대괄호와 콜론을
        -- 포함하므로, 이 위에서 이미 통과했어야 하는 도메인 문자 클래스
        -- 기반 구조 정규식(위 "https:// + 호스트..." 검사) 자체를 애초에
        -- 통과하지 못해 이 지점에 도달하기 전에 "외부 영상 링크 형식이
        -- 올바르지 않습니다"로 이미 차단된다 - 별도의 IPv6 처리가 이
        -- 아래에 필요하지 않다.
    END IF;

    RETURN NEW;
END;
$$;

-- =========================================================================
-- 실행 후 참고용 읽기 전용 검증 쿼리(전부 주석 처리, 자동 실행되지 않음)
-- =========================================================================

-- 함수 정의가 의도한 대로 교체됐는지 확인
-- SELECT pg_get_functiondef('public.enforce_video_artwork_paths()'::regprocedure);

-- 트리거가 여전히 정확히 1개만 있는지(중복 생성되지 않았는지) 확인
-- SELECT tgname, tgrelid::regclass, tgenabled
-- FROM pg_trigger
-- WHERE tgname = 'trg_enforce_video_artwork_paths';

-- image/document/text 작품이 이 트리거로 인해 하나도 막히지 않았는지
-- (0건이어야 정상 - media_type<>'video'면 즉시 통과하므로 애초에 막을 수
-- 없지만, 실행 직후 기존 데이터 기준으로 재확인용)
-- SELECT count(*) FROM public.artworks WHERE media_type IN ('image', 'document');

-- 기존(10) 버전 이후 저장된 직접 업로드 영상 작품이 여전히 정상 통과하는지
-- (media_url이 NOT NULL이고 external_url이 NULL인 기존 video 행은 이
-- 트리거를 다시 통과할 필요가 없다 - 이 쿼리는 실행 직후 새로 INSERT/
-- UPDATE되는 행을 위한 참고용일 뿐, 과거 행에는 이 트리거가 재적용되지
-- 않는다)
-- SELECT id, media_url, thumbnail_url, external_url
-- FROM public.artworks
-- WHERE media_type = 'video';
