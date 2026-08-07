-- =========================================================================
-- 온하다 플랫폼 Supabase 마이그레이션 - 01_schema.sql
-- 범위: 테이블, 제약조건, 인덱스만 정의
-- 이 파일에는 함수, 트리거, RLS 정책, Storage 정책, 시드 데이터를 넣지 않는다.
-- =========================================================================

-- gen_random_uuid() 사용을 위한 확장 (Supabase 프로젝트에는 보통 기본 활성화됨)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -------------------------------------------------------------------------
-- 1. categories : 작품 카테고리 정의 (디카시 / AI 미술 / 음악·영상)
-- -------------------------------------------------------------------------
CREATE TABLE public.categories (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

-- -------------------------------------------------------------------------
-- 2. profiles : auth.users와 1:1 매핑되는 권한 프로필
--    이메일은 auth.users가 원본이므로 중복 저장하지 않고 표시명만 저장한다.
-- -------------------------------------------------------------------------
CREATE TABLE public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    display_name TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'pending'
        CHECK (role IN ('pending', 'manager', 'admin')),
    manager_type TEXT
        CHECK (manager_type IN ('instructor', 'institution_staff')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    CONSTRAINT chk_profiles_manager_type CHECK (
        (role = 'manager' AND manager_type IS NOT NULL)
        OR (role IN ('pending', 'admin') AND manager_type IS NULL)
    )
);

-- -------------------------------------------------------------------------
-- 3. exhibitions : 전시관 (외부 Lovable 연동 및 내부 강사형 전시관 공통)
--    가상의 count/authors 수치는 저장하지 않고 exhibition_stats/artworks에서 계산한다.
--    데모 여부는 exhibition_type이 아닌 is_demo로만 관리한다.
-- -------------------------------------------------------------------------
CREATE TABLE public.exhibitions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT UNIQUE NOT NULL,
    -- legacy_id : 기존 app.html의 정적 전시관 id(예: art, museum)와 연결하기 위한
    -- 값. slug와 역할이 다르다 - slug는 신규 브라우저 접근용 고유 주소이고,
    -- legacy_id는 기존 UI(enterSpecificHall(id) 등)와의 호환·데이터 마이그레이션
    -- 전용이다. 신규로 만드는 전시관은 legacy_id가 없을 수 있으므로 NULL을 허용한다.
    legacy_id TEXT UNIQUE,
    title TEXT NOT NULL,
    description TEXT,
    -- tag : 전시관 카드에 노출할 짧은 주제 표기(예: AI 이미지·만화). 데이터
    -- 분류 기준인 exhibition_type과는 역할이 다른 순수 표시용 문구다.
    tag TEXT,
    organization_name TEXT,
    cover_image_path TEXT,
    exhibition_type TEXT NOT NULL
        CHECK (exhibition_type IN ('institution', 'instructor', 'personal')),
    operation_status TEXT NOT NULL
        CHECK (operation_status IN ('preparing', 'beta', 'operating', 'ended')),
    visibility TEXT NOT NULL
        CHECK (visibility IN ('public', 'unlisted', 'private')),
    is_demo BOOLEAN NOT NULL DEFAULT false,
    is_external BOOLEAN NOT NULL DEFAULT false,
    external_url TEXT,
    allow_comments BOOLEAN NOT NULL DEFAULT false,
    start_date DATE,
    end_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    CONSTRAINT chk_exhibitions_external_url CHECK (
        NOT is_external OR external_url IS NOT NULL
    )
);

-- -------------------------------------------------------------------------
-- 4. exhibition_stats : 외부 전시관의 실측 통계 이력 (수동/크롤러 수집)
-- -------------------------------------------------------------------------
CREATE TABLE public.exhibition_stats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exhibition_id UUID NOT NULL
        REFERENCES public.exhibitions (id) ON DELETE CASCADE,
    participant_count INTEGER NOT NULL DEFAULT 0
        CHECK (participant_count >= 0),
    artwork_count INTEGER NOT NULL DEFAULT 0
        CHECK (artwork_count >= 0),
    measured_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    source_type TEXT NOT NULL
        CHECK (source_type IN ('internal_aggregate', 'external_verified', 'manual_verified')),
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

-- -------------------------------------------------------------------------
-- 5. exhibition_managers : 전시관 담당 매니저(강사/기관 담당자) 매핑
-- -------------------------------------------------------------------------
CREATE TABLE public.exhibition_managers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exhibition_id UUID NOT NULL
        REFERENCES public.exhibitions (id) ON DELETE CASCADE,
    profile_id UUID NOT NULL
        REFERENCES public.profiles (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    CONSTRAINT uq_exhibition_manager UNIQUE (exhibition_id, profile_id)
);

-- -------------------------------------------------------------------------
-- 6. artworks : 작품 (이미지/영상/음악/텍스트 공통, 특정 미디어를 강제하지 않음)
-- -------------------------------------------------------------------------
CREATE TABLE public.artworks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exhibition_id UUID NOT NULL
        REFERENCES public.exhibitions (id) ON DELETE CASCADE,
    category_id TEXT NOT NULL
        REFERENCES public.categories (id),
    title TEXT NOT NULL,
    media_type TEXT NOT NULL
        CHECK (media_type IN ('image', 'video', 'audio', 'text', 'document', 'mixed')),
    thumbnail_url TEXT,
    media_url TEXT,
    external_url TEXT,
    artist_display_name TEXT NOT NULL,
    artist_age INTEGER
        CHECK (artist_age IS NULL OR artist_age >= 0),
    artist_age_public BOOLEAN NOT NULL DEFAULT false,
    description TEXT,
    poem TEXT,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'rejected', 'hidden')),
    rejection_reason TEXT,
    consent_confirmed BOOLEAN NOT NULL DEFAULT false,
    consent_scope TEXT,
    submitted_by UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    approved_by UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    CONSTRAINT chk_artworks_approval_requires_consent CHECK (
        status <> 'approved' OR consent_confirmed = true
    )
);

-- -------------------------------------------------------------------------
-- 7. artwork_comments : 작품 댓글 (기본 승인 대기 상태로 등록)
-- -------------------------------------------------------------------------
CREATE TABLE public.artwork_comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    artwork_id UUID NOT NULL
        REFERENCES public.artworks (id) ON DELETE CASCADE,
    author TEXT NOT NULL,
    content TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'rejected', 'hidden')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

-- -------------------------------------------------------------------------
-- 8. artwork_likes : 세션 기반 중복 좋아요 방지 매핑
-- -------------------------------------------------------------------------
CREATE TABLE public.artwork_likes (
    artwork_id UUID NOT NULL
        REFERENCES public.artworks (id) ON DELETE CASCADE,
    session_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    PRIMARY KEY (artwork_id, session_id)
);

-- -------------------------------------------------------------------------
-- 인덱스 : 자주 조회되는 컬럼 위주로만 생성
-- -------------------------------------------------------------------------
CREATE INDEX idx_exhibitions_visibility
    ON public.exhibitions (visibility);

CREATE INDEX idx_exhibition_stats_exhibition_id
    ON public.exhibition_stats (exhibition_id);

CREATE INDEX idx_exhibition_managers_profile_id
    ON public.exhibition_managers (profile_id);

-- exhibition_id 단독 조회는 아래 복합 인덱스의 선두 컬럼으로 커버되므로
-- 별도의 idx_artworks_exhibition_id 단일 인덱스는 만들지 않는다.
CREATE INDEX idx_artworks_exhibition_status_created
    ON public.artworks (exhibition_id, status, created_at DESC);

CREATE INDEX idx_artworks_category_id
    ON public.artworks (category_id);

-- 전시관 구분 없이 상태만으로 필터링하는 관리자 전체 승인 대기함 조회용
CREATE INDEX idx_artworks_status
    ON public.artworks (status);

-- 전시관 구분 없이 전체 최신순으로 조회하는 플랫폼 전역 피드용
CREATE INDEX idx_artworks_created_at
    ON public.artworks (created_at DESC);

CREATE INDEX idx_artwork_comments_artwork_id
    ON public.artwork_comments (artwork_id);

CREATE INDEX idx_artwork_comments_status
    ON public.artwork_comments (status);
