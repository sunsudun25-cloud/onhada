-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 04_seed_test.sql
-- 범위: 1차 시드 데이터만 (카테고리, 실제 외부 운영 전시관 2개, 그 확인 실적
-- 2건, 비공개 시스템 테스트 전시관 1개, 개인정보 없는 pending 테스트 작품 1개).
--
-- 디카시정원, 은빛 나래 미술관, 기존 내부 목업 전시관, 가상 1인 전시관은
-- 이번 1차 시드에서 의도적으로 제외한다.
--
-- 이 파일은 DB 행만 생성한다. test-pine.jpg 실제 파일은 Storage에 자동으로
-- 생성하지 않는다. Storage 테스트가 필요하면 아래 경로에 별도로 이미지를
-- 직접 업로드해야 한다.
--   00000000-0000-0000-0000-000000000009/test-pine.jpg
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. categories
-- -------------------------------------------------------------------------
INSERT INTO public.categories (id, name, description) VALUES
    ('dicasi', '디카시', '사진과 짧은 글이 결합된 창작 장르'),
    ('ai_art', 'AI 미술', '생성형 AI로 제작한 이미지 창작물'),
    ('storybook', 'AI 동화책', 'AI를 활용해 제작한 그림 동화책'),
    ('music', '음악', '직접 작사·작곡하거나 편곡한 음악'),
    ('music_video', '뮤직비디오', '음악에 영상을 결합한 뮤직비디오'),
    ('writing', '글쓰기', '수필·편지·자서전 등 글쓰기 창작물'),
    ('photo', '사진', '사진 촬영 및 편집 창작물'),
    ('mixed', '복합 창작', '두 가지 이상의 장르가 결합된 창작물')
ON CONFLICT (id) DO NOTHING;

-- -------------------------------------------------------------------------
-- 2. 실제 외부 운영 전시관 2개 + 비공개 시스템 테스트 전시관 1개
--    고정 UUID + ON CONFLICT (id) DO NOTHING: 재실행해도 기존 행을 덮어쓰지
--    않아 운영 중 바뀐 값(예: operation_status)이 시드 재실행으로 초기화되지
--    않는다.
-- -------------------------------------------------------------------------
-- cover_image_path 값은 app.html의 INITIAL_HALLS에 실제로 쓰인 img 값을
-- 그대로 가져온 것이다(art -> 상상의바다_갤러리.png, museum -> 온뮤지엄 상세.png).
-- test-hall은 INITIAL_HALLS에 대응하는 항목이 없어, app.html 안에서 특정
-- 기관에 속하지 않는 범용/시스템 플레이스홀더로 이미 쓰이고 있는
-- "온라인 전시장 .png"(코치 목업 산출물의 기본 이미지로 반복 사용됨)를
-- 그대로 재사용했다.
INSERT INTO public.exhibitions (
    id, slug, legacy_id, title, description, tag, organization_name,
    cover_image_path, exhibition_type, operation_status, visibility,
    is_demo, is_external, external_url, allow_comments
) VALUES
    -- 2-1. 상상의 바다 갤러리 (영도구노인복지관, 실제 운영, 외부 Lovable 연동)
    (
        '00000000-0000-0000-0000-000000000001',
        'on-sea-gallery',
        'art',
        '상상의 바다 갤러리',
        'AI 이미지와 만화 등 시니어의 디지털 창작 작품을 전시합니다.',
        'AI 이미지·만화',
        '영도구노인복지관',
        '상상의바다_갤러리.png',
        'institution',
        'operating',
        'public',
        false,
        true,
        'https://on-sea-gallery.lovable.app',
        false
    ),
    -- 2-2. 빛의 사운드 뮤지엄 (동래구노인복지관, 실제 운영, 외부 Lovable 연동)
    (
        '00000000-0000-0000-0000-000000000002',
        'light-sound-museum',
        'museum',
        '빛의 사운드 뮤지엄',
        '시니어가 직접 만든 회상 음악과 뮤직비디오를 감상합니다.',
        '회상 음악·뮤직비디오',
        '동래구노인복지관',
        '온뮤지엄 상세.png',
        'institution',
        'operating',
        'public',
        false,
        true,
        'https://onmuseum.lovable.app',
        false
    ),
    -- 2-3. 온하다 강사형 테스트 전시관 (비공개, is_demo=true, 실제 통계 제외 대상)
    (
        '00000000-0000-0000-0000-000000000009',
        'onhada-test-hall',
        'test-hall',
        '온하다 강사형 테스트 전시관',
        '시스템 및 권한 검증을 위한 비공개 테스트 전시 공간입니다.',
        '시스템 검증',
        '온하다 플랫폼',
        '온라인 전시장 .png',
        'instructor',
        'preparing',
        'private',
        true,
        false,
        NULL,
        false
    )
ON CONFLICT (id) DO NOTHING;

-- -------------------------------------------------------------------------
-- 3. 실제 확인 통계 2건 (외부 운영 전시관에만 기록, 테스트 전시관은 제외)
--    exhibition_stats는 시간에 따라 여러 스냅샷이 쌓이는 이력 테이블이라
--    자연 키가 없다. 재실행 시마다 새 통계 행이 계속 쌓이지 않도록
--    id에도 고정 UUID를 부여하고 ON CONFLICT (id) DO NOTHING을 적용한다.
--    참여자 합계 13+15=28명, 작품 합계 20+15=35점.
-- -------------------------------------------------------------------------
INSERT INTO public.exhibition_stats (
    id, exhibition_id, participant_count, artwork_count, source_type, note
) VALUES
    (
        '00000000-0000-0000-0000-000000000101',
        '00000000-0000-0000-0000-000000000001',
        13,
        20,
        'external_verified',
        '외부 Lovable 운영 전시관 확인 실적'
    ),
    (
        '00000000-0000-0000-0000-000000000102',
        '00000000-0000-0000-0000-000000000002',
        15,
        15,
        'external_verified',
        '외부 Lovable 운영 전시관 확인 실적'
    )
ON CONFLICT (id) DO NOTHING;

-- -------------------------------------------------------------------------
-- 4. 개인정보가 없는 pending 테스트 작품 1개
--    consent_confirmed=false 상태로 등록해 "동의 없이는 승인 불가" 보안
--    규칙(chk_artworks_approval_requires_consent 제약, enforce_artwork_status
--    트리거, approve_artwork RPC의 3중 방어)을 검증하는 용도로 사용한다.
--    submitted_by를 NULL로 둔 것은 이 행이 실제 manager의 RLS 경유 제출이
--    아니라 시스템 시드로 직접 삽입되는 합성 테스트 자료이기 때문이다.
--
--    실제 승인 흐름 테스트 순서(이 파일 실행만으로는 진행되지 않으며,
--    아래는 이후 수동 검증 절차 안내):
--      1. consent_confirmed=false 상태에서 approve_artwork RPC 호출 시
--         거부되는지 확인
--      2. 이 작품이 실존 인물 정보 없는 합성 테스트 자료임을 재확인
--      3. 테스트 목적으로 consent_confirmed=true로 수동 UPDATE
--      4. approve_artwork RPC로 관리자 승인 수행
--      5. 승인 후에도 소속 전시관(onhada-test-hall)이 visibility=private이라
--         비회원 화면(anon SELECT 정책)에는 노출되지 않는지 확인
-- -------------------------------------------------------------------------
INSERT INTO public.artworks (
    id, exhibition_id, category_id, title, media_type, media_url,
    artist_display_name, artist_age, artist_age_public,
    description, poem, status, consent_confirmed, consent_scope
) VALUES (
    '99999999-9999-9999-9999-999999999999',
    '00000000-0000-0000-0000-000000000009',
    'dicasi',
    '테스트 청춘 소나무',
    'image',
    '00000000-0000-0000-0000-000000000009/test-pine.jpg',
    'TEST-ARTIST-01',
    NULL,
    false,
    '솔향 가득한 소나무 아래에서 추억을 표현한 시스템 테스트 작품',
    E'바람 부는 날에도 푸른 옷 입고\n한결같이 서 있는 굳센 소나무여.',
    'pending',
    false,
    'synthetic_test_asset_no_personal_data'
)
ON CONFLICT (id) DO NOTHING;


-- =========================================================================
-- 검증 쿼리 (실행되지 않는 주석. 필요할 때 직접 복사해 실행할 것)
-- =========================================================================

-- 1. 실제 외부 운영 전시관 2개 조회
-- SELECT id, slug, title, organization_name, operation_status, is_demo
-- FROM public.exhibitions
-- WHERE is_external = true AND is_demo = false;

-- 2. 참여자 합계 28명 확인
-- SELECT sum(participant_count) AS total_participants
-- FROM public.exhibition_stats
-- WHERE exhibition_id IN (
--     '00000000-0000-0000-0000-000000000001',
--     '00000000-0000-0000-0000-000000000002'
-- );

-- 3. 작품 합계 35점 확인
-- SELECT sum(artwork_count) AS total_artworks
-- FROM public.exhibition_stats
-- WHERE exhibition_id IN (
--     '00000000-0000-0000-0000-000000000001',
--     '00000000-0000-0000-0000-000000000002'
-- );

-- 4. is_demo=true 테스트 전시관이 실제 통계에서 제외되는지 확인
--    (아래 쿼리는 0행이 나와야 정상 - 테스트 전시관용 통계 행이 없어야 함)
-- SELECT es.*
-- FROM public.exhibition_stats es
-- JOIN public.exhibitions ex ON ex.id = es.exhibition_id
-- WHERE ex.is_demo = true;

-- 5. 테스트 작품 status=pending, consent_confirmed=false 확인
-- SELECT id, title, status, consent_confirmed, consent_scope
-- FROM public.artworks
-- WHERE id = '99999999-9999-9999-9999-999999999999';

-- 6. 디카시정원·은빛 나래·기존 가상 전시관이 없는지 확인 (0행이 나와야 정상)
-- SELECT id, slug, title
-- FROM public.exhibitions
-- WHERE slug IN ('dikasi-garden', 'onartgallery', 'silver-wings')
--    OR title LIKE '%디카시정원%'
--    OR title LIKE '%은빛 나래%';
