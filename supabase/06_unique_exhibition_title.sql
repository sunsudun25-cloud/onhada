-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 06_unique_exhibition_title.sql
-- 목적: public.exhibitions.title의 공백·구분점(·) 표기 차이를 무시하고,
--       동일한 공개 표시 이름이 중복 저장되지 않도록 DB 수준 UNIQUE
--       표현식 인덱스를 추가한다.
--
-- [실행 전 필수 확인] 이 파일을 실행하기 전에 반드시 아래 쿼리로 현재
-- exhibitions에 정규화 기준 중복 title이 0건인지 먼저 확인해야 한다.
-- 1건이라도 있으면 CREATE UNIQUE INDEX가 실패하므로, 실행 전에 그 행들을
-- 먼저 별도로 정리(제목 수정 등)해야 한다.
--
--   SELECT
--       lower(
--           regexp_replace(
--               regexp_replace(
--                   btrim(title),
--                   '[[:space:]]*·[[:space:]]*',
--                   '·',
--                   'g'
--               ),
--               '[[:space:]]+',
--               ' ',
--               'g'
--           )
--       ) AS normalized_title,
--       count(*)
--   FROM public.exhibitions
--   GROUP BY 1
--   HAVING count(*) > 1;
--
-- [정규화 규칙]
--   1. btrim(title)                         : 앞뒤 공백 제거
--   2. '·' 앞뒤 공백 제거(연속 공백 포함)     : "예술관 · 동래" -> "예술관·동래"
--   3. 남은 연속 공백을 한 칸으로 정리         : "온하다  예술관" -> "온하다 예술관"
--   4. lower 적용                            : 영문 대소문자 무시
--
-- 예를 들어 다음 세 값은 모두 동일한 것으로 취급되어 중복 차단된다.
--   - 온하다 미래관 · 순자의 봄
--   - 온하다 미래관·순자의 봄
--   - 온하다 미래관  ·  순자의 봄
--
-- title은 NOT NULL 컬럼이므로(01_schema.sql 참조) NULL에 대한 별도 처리는
-- 필요 없다.
--
-- IF NOT EXISTS를 쓰지 않는다 - 이미 같은 이름의 인덱스가 있거나 배포
-- 상태가 꼬여 있는 경우, 그 문제를 조용히 넘기지 않고 명확한 오류로
-- 드러나야 한다.
-- =========================================================================

CREATE UNIQUE INDEX uq_exhibitions_normalized_title
ON public.exhibitions (
    (
        lower(
            regexp_replace(
                regexp_replace(
                    btrim(title),
                    '[[:space:]]*·[[:space:]]*',
                    '·',
                    'g'
                ),
                '[[:space:]]+',
                ' ',
                'g'
            )
        )
    )
);

-- =========================================================================
-- [검증용 - 실행하지 말고 참고만 할 것]
-- 아래 쿼리로 인덱스가 정확히 생성됐는지 확인할 수 있다.
--
--   SELECT indexname, indexdef
--   FROM pg_indexes
--   WHERE schemaname = 'public'
--     AND tablename = 'exhibitions'
--     AND indexname = 'uq_exhibitions_normalized_title';
-- =========================================================================
