(function () {
    window.ONHADA_BACKEND = window.ONHADA_BACKEND || {};

    function getClient() {
        return window.ONHADA_BACKEND && window.ONHADA_BACKEND.client;
    }

    function getAuth() {
        return window.ONHADA_BACKEND && window.ONHADA_BACKEND.auth;
    }

    function safeError(code, message) {
        return { code: code, message: message };
    }

    var DB_UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    function isValidUuid(value) {
        return typeof value === 'string' && DB_UUID_RE.test(value);
    }

    // title로부터 안전한 slug를 만든다. 원본 title이나 개인정보를 console에
    // 출력하지 않는다. 영문 소문자/숫자/한글/하이픈만 남기고, 끝에
    // crypto.randomUUID()의 앞 8자를 붙여 처음부터 고유 가능성을 높인다.
    function onhadaBuildExhibitionSlug(title) {
        var normalized = (typeof title === 'string' ? title : '').normalize('NFKC').trim().toLowerCase();
        normalized = normalized.replace(/\s+/g, '-');
        normalized = normalized.replace(/[^a-z0-9가-힣-]/g, '');
        normalized = normalized.replace(/-+/g, '-');
        normalized = normalized.replace(/^-+|-+$/g, '');

        if (!normalized) {
            normalized = 'exhibition';
        }

        var base = normalized.slice(0, 60);
        var suffix = crypto.randomUUID().slice(0, 8);
        return base + '-' + suffix;
    }

    function flattenRow(row) {
        const ex = row && row.exhibitions;
        if (!ex) return null;

        return {
            id: ex.id,
            slug: ex.slug,
            legacy_id: ex.legacy_id,
            title: ex.title,
            tag: ex.tag,
            organization_name: ex.organization_name,
            cover_image_path: ex.cover_image_path,
            exhibition_type: ex.exhibition_type,
            operation_status: ex.operation_status,
            visibility: ex.visibility,
            is_demo: ex.is_demo,
            allow_comments: ex.allow_comments
        };
    }

    function stableSortByTitle(list) {
        return list
            .map(function (item, index) { return { item: item, index: index }; })
            .sort(function (a, b) {
                const titleA = a.item.title || '';
                const titleB = b.item.title || '';
                if (titleA < titleB) return -1;
                if (titleA > titleB) return 1;
                return a.index - b.index;
            })
            .map(function (wrapped) { return wrapped.item; });
    }

    async function getMyManagedExhibitions() {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, exhibitions: [], error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, exhibitions: [], error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, exhibitions: [], error: safeError('role_not_allowed', '담당 전시관 조회는 운영자 계정만 가능합니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, exhibitions: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('exhibition_managers')
                .select(`
                    exhibition_id,
                    exhibitions (
                        id,
                        slug,
                        legacy_id,
                        title,
                        tag,
                        organization_name,
                        cover_image_path,
                        exhibition_type,
                        operation_status,
                        visibility,
                        is_demo,
                        allow_comments
                    )
                `)
                .eq('profile_id', context.userId);

            if (error) {
                return { ok: false, exhibitions: [], error: safeError('exhibitions_fetch_failed', '담당 전시관 목록을 불러오지 못했습니다.') };
            }

            const rows = Array.isArray(data) ? data : [];
            const flattened = rows.map(flattenRow).filter(function (item) { return item !== null; });
            const sorted = stableSortByTitle(flattened);

            return { ok: true, exhibitions: sorted, error: null };
        } catch (err) {
            return { ok: false, exhibitions: [], error: safeError('unexpected_error', '담당 전시관 조회 중 오류가 발생했습니다.') };
        }
    }

    async function getManagedArtworks(exhibitionId) {
        if (!exhibitionId) {
            return { ok: false, artworks: [], error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, artworks: [], error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, artworks: [], error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, artworks: [], error: safeError('role_not_allowed', '작품 조회는 운영자 계정만 가능합니다.') };
        }

        const managedResult = await getMyManagedExhibitions();

        if (!managedResult.ok) {
            return { ok: false, artworks: [], error: managedResult.error };
        }

        const isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionId; });

        if (!isManaged) {
            return { ok: false, artworks: [], error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, artworks: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('artworks')
                .select(`
                    id,
                    exhibition_id,
                    submitted_by,
                    title,
                    category_id,
                    media_type,
                    artist_display_name,
                    description,
                    media_url,
                    thumbnail_url,
                    external_url,
                    status,
                    consent_confirmed,
                    rejection_reason,
                    created_at,
                    updated_at,
                    categories (
                        id,
                        name
                    )
                `)
                .eq('exhibition_id', exhibitionId)
                .order('created_at', { ascending: false });

            if (error) {
                return { ok: false, artworks: [], error: safeError('artworks_fetch_failed', '작품 목록을 불러오지 못했습니다.') };
            }

            const rows = Array.isArray(data) ? data : [];

            return { ok: true, artworks: rows, error: null };
        } catch (err) {
            return { ok: false, artworks: [], error: safeError('unexpected_error', '작품 목록 조회 중 오류가 발생했습니다.') };
        }
    }

    async function getCategories() {
        const client = getClient();
        if (!client) {
            return { ok: false, categories: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('categories')
                .select('id, name')
                .order('name', { ascending: true });

            if (error) {
                return { ok: false, categories: [], error: safeError('categories_fetch_failed', '카테고리 목록을 불러오지 못했습니다.') };
            }

            return { ok: true, categories: Array.isArray(data) ? data : [], error: null };
        } catch (err) {
            return { ok: false, categories: [], error: safeError('unexpected_error', '카테고리 조회 중 오류가 발생했습니다.') };
        }
    }

    // 인증 없이 호출 가능. RLS(exhibitions_select_public)가 최종 보안 경계이며,
    // 여기서 붙이는 .eq() 조건은 프런트 표시 목적의 명시적 질의일 뿐 그 자체로
    // 보안을 담보하지 않는다 - RLS가 없어도 이 조건이 그대로 강제된다고
    // 가정하지 않는다.
    async function getPublicExhibitions() {
        const client = getClient();
        if (!client) {
            return { ok: false, exhibitions: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('exhibitions')
                .select(`
                    id,
                    slug,
                    legacy_id,
                    title,
                    description,
                    tag,
                    organization_name,
                    cover_image_path,
                    exhibition_type,
                    allow_comments,
                    is_demo,
                    exhibition_stats (
                        participant_count,
                        artwork_count
                    )
                `)
                .eq('visibility', 'public')
                .eq('operation_status', 'operating');

            if (error) {
                return { ok: false, exhibitions: [], error: safeError('exhibitions_fetch_failed', '공개 전시관 목록을 불러오지 못했습니다.') };
            }

            return { ok: true, exhibitions: Array.isArray(data) ? data : [], error: null };
        } catch (err) {
            return { ok: false, exhibitions: [], error: safeError('unexpected_error', '공개 전시관 조회 중 오류가 발생했습니다.') };
        }
    }

    // 인증 없이 호출 가능. RLS(artworks_select_public)가 최종 보안 경계이지만,
    // 이 함수는 "공개 관람객 전용"이라는 의미 자체를 호출자의 role과 무관하게
    // 강제해야 한다. manager/admin으로 로그인한 상태에서 호출하면
    // artworks_select_manager/admin RLS가 동시에 적용돼 RLS만으로는
    // private/preparing 전시관의 작품까지 보일 수 있으므로, exhibitions를
    // !inner로 조인해 status='approved' AND visibility='public' AND
    // operation_status='operating'을 질의 조건에 명시적으로 강제한다.
    // exhibitions!inner 없이 status='approved'만 걸면(이전 구현) 그 전시관
    // 자체의 공개 여부는 검사하지 않게 되는 것이 문제였다.
    async function getPublicArtworksForExhibition(exhibitionId) {
        if (!exhibitionId) {
            return { ok: false, artworks: [], error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, artworks: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('artworks')
                .select(`
                    id,
                    title,
                    media_type,
                    artist_display_name,
                    category_id,
                    thumbnail_url,
                    media_url,
                    description,
                    poem,
                    categories (
                        id,
                        name
                    ),
                    exhibitions!inner (
                        visibility,
                        operation_status
                    )
                `)
                .eq('exhibition_id', exhibitionId)
                .eq('status', 'approved')
                .eq('exhibitions.visibility', 'public')
                .eq('exhibitions.operation_status', 'operating');

            if (error) {
                return { ok: false, artworks: [], error: safeError('artworks_fetch_failed', '공개 작품 목록을 불러오지 못했습니다.') };
            }

            const rows = Array.isArray(data) ? data : [];

            // exhibitions는 조인 필터링에만 사용하고, 반환 데이터에는 기존에
            // 승인한 공개 작품 필드만 남긴다(전시관 내부 정보 제거).
            const publicArtworks = rows.map(function (row) {
                return {
                    id: row.id,
                    title: row.title,
                    media_type: row.media_type,
                    artist_display_name: row.artist_display_name,
                    category_id: row.category_id,
                    thumbnail_url: row.thumbnail_url,
                    media_url: row.media_url,
                    description: row.description,
                    poem: row.poem,
                    categories: row.categories
                };
            });

            return { ok: true, artworks: publicArtworks, error: null };
        } catch (err) {
            return { ok: false, artworks: [], error: safeError('unexpected_error', '공개 작품 조회 중 오류가 발생했습니다.') };
        }
    }

    async function createManagedArtwork(exhibitionId, input) {
        const client = getClient();
        if (!client) {
            return { ok: false, artwork: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        if (!exhibitionId) {
            return { ok: false, artwork: null, error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, artwork: null, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, artwork: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, artwork: null, error: safeError('role_not_allowed', '작품 등록은 운영자 계정만 가능합니다.') };
        }

        const managedResult = await getMyManagedExhibitions();

        if (!managedResult.ok) {
            return { ok: false, artwork: null, error: managedResult.error };
        }

        const isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionId; });

        if (!isManaged) {
            return { ok: false, artwork: null, error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        // input을 그대로 스프레드하지 않고 화이트리스트 필드만 꺼낸다.
        const safeInput = input || {};
        const title = typeof safeInput.title === 'string' ? safeInput.title.trim() : '';
        const artistDisplayName = typeof safeInput.artist_display_name === 'string' ? safeInput.artist_display_name.trim() : '';
        const categoryId = typeof safeInput.category_id === 'string' ? safeInput.category_id : '';
        const descriptionTrimmed = typeof safeInput.description === 'string' ? safeInput.description.trim() : '';
        const poem = typeof safeInput.poem === 'string' ? safeInput.poem.trim() : '';
        const consentConfirmed = safeInput.consent_confirmed === true;

        const categoriesResult = await getCategories();

        if (!categoriesResult.ok) {
            return { ok: false, artwork: null, error: categoriesResult.error };
        }

        const categoryExists = categoriesResult.categories.some(function (cat) { return cat.id === categoryId; });

        if (!categoryExists) {
            return { ok: false, artwork: null, error: safeError('invalid_category', '카테고리를 선택해 주세요.') };
        }

        if (!title || title.length > 100) {
            return { ok: false, artwork: null, error: safeError('invalid_title', '작품명을 100자 이내로 입력해 주세요.') };
        }

        if (!artistDisplayName || artistDisplayName.length > 50) {
            return { ok: false, artwork: null, error: safeError('invalid_artist_display_name', '작가 표시명을 50자 이내로 입력해 주세요.') };
        }

        if (descriptionTrimmed.length > 500) {
            return { ok: false, artwork: null, error: safeError('invalid_description', '작품 설명은 500자를 초과할 수 없습니다.') };
        }

        if (!poem || poem.length > 2000) {
            return { ok: false, artwork: null, error: safeError('invalid_poem', '글/시 내용을 2000자 이내로 입력해 주세요.') };
        }

        // UI 체크박스를 우회하더라도 여기서 다시 한번 동의 여부를 강제한다.
        if (!consentConfirmed) {
            return { ok: false, artwork: null, error: safeError('consent_required', '전시 동의 확인이 필요합니다.') };
        }

        const payload = {
            exhibition_id: exhibitionId,
            category_id: categoryId,
            title: title,
            media_type: 'text',
            artist_display_name: artistDisplayName,
            description: descriptionTrimmed.length > 0 ? descriptionTrimmed : null,
            poem: poem,
            status: 'pending',
            consent_confirmed: true,
            consent_scope: 'online_exhibition_confirmed_by_operator',
            submitted_by: context.userId
        };

        try {
            const { data, error } = await client
                .from('artworks')
                .insert(payload)
                .select('id, exhibition_id, category_id, title, media_type, artist_display_name, status, consent_confirmed, created_at')
                .single();

            if (error) {
                return { ok: false, artwork: null, error: safeError('artwork_create_failed', '작품 등록에 실패했습니다.') };
            }

            return { ok: true, artwork: data, error: null };
        } catch (err) {
            return { ok: false, artwork: null, error: safeError('unexpected_error', '작품 등록 중 오류가 발생했습니다.') };
        }
    }

    var MANAGED_IMAGE_PATH_UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    var MANAGED_IMAGE_PATH_FILE_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$/i;

    // media_path는 storage-service.js가 생성한 {exhibitionId}/{randomUuid}.{ext}
    // 형식의 object path 문자열이어야 한다. URL, 절대경로, 상위 경로 이동,
    // 역슬래시, 공백, query string/fragment는 전부 허용하지 않는다.
    function isValidManagedImagePath(mediaPath, exhibitionId) {
        if (typeof mediaPath !== 'string' || mediaPath.length === 0) return false;
        if (mediaPath.indexOf('://') !== -1) return false;
        if (mediaPath.charAt(0) === '/') return false;
        if (mediaPath.indexOf('\\') !== -1) return false;
        if (mediaPath.indexOf(' ') !== -1) return false;
        if (mediaPath.indexOf('?') !== -1) return false;
        if (mediaPath.indexOf('#') !== -1) return false;
        if (mediaPath.indexOf('..') !== -1) return false;

        var segments = mediaPath.split('/');
        if (segments.length !== 2) return false;

        var exhibitionSegment = segments[0];
        var fileSegment = segments[1];

        if (exhibitionSegment !== exhibitionId) return false;
        if (!MANAGED_IMAGE_PATH_UUID_RE.test(exhibitionSegment)) return false;
        if (!MANAGED_IMAGE_PATH_FILE_RE.test(fileSegment)) return false;

        return true;
    }

    // PDF 문서 전용 비공개 path validator. isValidManagedImagePath()는 건드리지
    // 않고 완전히 별도로 둔다. 폴더 구간(UUID) 검증 정규식은 이미지와 동일한
    // MANAGED_IMAGE_PATH_UUID_RE를 그대로 재사용하되, 파일명 확장자만 .pdf로 한정한다.
    var MANAGED_DOCUMENT_PDF_PATH_FILE_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$/i;

    function isValidManagedDocumentPdfPath(mediaPath, exhibitionId) {
        if (typeof mediaPath !== 'string' || mediaPath.length === 0) return false;
        if (mediaPath.indexOf('://') !== -1) return false;
        if (mediaPath.charAt(0) === '/') return false;
        if (mediaPath.indexOf('\\') !== -1) return false;
        if (mediaPath.indexOf(' ') !== -1) return false;
        if (mediaPath.indexOf('?') !== -1) return false;
        if (mediaPath.indexOf('#') !== -1) return false;
        if (mediaPath.indexOf('..') !== -1) return false;

        var segments = mediaPath.split('/');
        if (segments.length !== 2) return false;

        var exhibitionSegment = segments[0];
        var fileSegment = segments[1];

        if (exhibitionSegment !== exhibitionId) return false;
        if (!MANAGED_IMAGE_PATH_UUID_RE.test(exhibitionSegment)) return false;
        if (!MANAGED_DOCUMENT_PDF_PATH_FILE_RE.test(fileSegment)) return false;

        return true;
    }

    // 영상(MP4) 전용 비공개 path validator. isValidManagedImagePath()/
    // isValidManagedDocumentPdfPath()는 건드리지 않고 완전히 별도로 둔다.
    // 폴더 구간(UUID) 검증 정규식은 동일하게 MANAGED_IMAGE_PATH_UUID_RE를
    // 재사용하되, 파일명 확장자만 .mp4로 한정한다.
    var MANAGED_VIDEO_PATH_FILE_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.mp4$/i;

    function isValidManagedVideoPath(mediaPath, exhibitionId) {
        if (typeof mediaPath !== 'string' || mediaPath.length === 0) return false;
        if (mediaPath.indexOf('://') !== -1) return false;
        if (mediaPath.charAt(0) === '/') return false;
        if (mediaPath.indexOf('\\') !== -1) return false;
        if (mediaPath.indexOf(' ') !== -1) return false;
        if (mediaPath.indexOf('?') !== -1) return false;
        if (mediaPath.indexOf('#') !== -1) return false;
        if (mediaPath.indexOf('..') !== -1) return false;

        var segments = mediaPath.split('/');
        if (segments.length !== 2) return false;

        var exhibitionSegment = segments[0];
        var fileSegment = segments[1];

        if (exhibitionSegment !== exhibitionId) return false;
        if (!MANAGED_IMAGE_PATH_UUID_RE.test(exhibitionSegment)) return false;
        if (!MANAGED_VIDEO_PATH_FILE_RE.test(fileSegment)) return false;

        return true;
    }

    // 외부(Lovable 등) MP4 직접 링크 전용 검증. UI(app.html)가 이미 같은
    // 종류의 검증을 하더라도, 이 함수는 그 결과를 신뢰하지 않고 여기서
    // 다시 독립적으로 검증한다 - 이 파일의 다른 화이트리스트 검증(제목/
    // 작가명/동의 등)과 동일한 원칙이다. DNS 조회나 실제 파일 접근은 하지
    // 않고(브라우저에서 네트워크 요청 없이 판단 가능한) 문자열 구조만
    // 검사한다.
    var EXTERNAL_VIDEO_URL_MAX_LENGTH = 2048;

    // IPv4 주소의 첫째·둘째 옥텟(a, b)이 루프백(127.x) 또는 사설 대역
    // (10.x, 172.16~31.x, 192.168.x, 169.254.x) 또는 미지정(0.x)에
    // 속하는지 판정한다. isValidExternalVideoUrl()이 일반 IPv4 표기와
    // IPv4-매핑 IPv6 표기 양쪽에서 공통으로 사용한다.
    function isPrivateOrLoopbackIPv4Octets(a, b) {
        return a === 10 || a === 127 || a === 0
            || (a === 172 && b >= 16 && b <= 31)
            || (a === 192 && b === 168)
            || (a === 169 && b === 254);
    }

    function isValidExternalVideoUrl(url) {
        if (typeof url !== 'string' || url.length === 0 || url.length > EXTERNAL_VIDEO_URL_MAX_LENGTH) {
            return false;
        }

        var parsed;
        try {
            parsed = new URL(url);
        } catch (err) {
            return false;
        }

        if (parsed.protocol !== 'https:') return false;
        if (parsed.username || parsed.password) return false;
        if (parsed.port) return false;
        if (parsed.hash) return false;
        if (!/\.mp4$/i.test(parsed.pathname)) return false;

        // new URL()은 IPv4 8진수·정수·16진수·축약 표기(예: "0177.0.0.1",
        // "2130706433", "0x7f000001", "127.1")를 이미 표준 점십진수로,
        // IPv6는 압축 표기로 정규화한다. 아래 검사는 원본 문자열의 표기
        // 방식이 아니라 이 "최종 정규화된" hostname이 실제로 가리키는
        // 주소를 기준으로 판단하므로 표기 방식을 바꾸는 우회에 영향받지 않는다.
        var hostname = parsed.hostname.toLowerCase();

        // 끝에 마침표가 붙은 호스트(FQDN 루트 표기, 예: "localhost.")는
        // 마침표를 지우고 다시 검사하지 않고 그 자체로 차단한다 - 지운 뒤
        // 검사하면 "localhost."가 "localhost"와 다른 문자열이라는 이유로
        // 아래 리터럴 차단을 우회하게 된다.
        if (hostname.charAt(hostname.length - 1) === '.') {
            return false;
        }

        if (hostname === 'localhost') {
            return false;
        }

        var ipv4Match = hostname.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
        if (ipv4Match) {
            var octets = [
                parseInt(ipv4Match[1], 10),
                parseInt(ipv4Match[2], 10),
                parseInt(ipv4Match[3], 10),
                parseInt(ipv4Match[4], 10)
            ];
            if (octets.some(function (n) { return n > 255; })) return false;
            if (isPrivateOrLoopbackIPv4Octets(octets[0], octets[1])) return false;
        }

        if (hostname.indexOf(':') !== -1) {
            var v6 = hostname.replace(/^\[/, '').replace(/\]$/, '');
            if (v6 === '::1' || v6.indexOf('fe80:') === 0 || v6.indexOf('fc00:') === 0 || v6.indexOf('fd00:') === 0) {
                return false;
            }
            // IPv4-매핑 IPv6("::ffff:127.0.0.1" 같은 주소는 new URL()에 의해
            // "::ffff:7f00:1" 형태의 16진수 압축 표기로 정규화된다)에 내장된
            // IPv4 주소를 16진수 두 그룹에서 복원해 동일한 사설/루프백 판정을 적용한다.
            var mappedMatch = v6.match(/^::ffff:([0-9a-f]{1,4}):(?:[0-9a-f]{1,4})$/);
            if (mappedMatch) {
                var hi = parseInt(mappedMatch[1], 16);
                var mappedA = (hi >> 8) & 0xff;
                var mappedB = hi & 0xff;
                if (isPrivateOrLoopbackIPv4Octets(mappedA, mappedB)) return false;
            }
        }

        return true;
    }

    // 이 함수는 storage-service.js를 직접 호출하지 않는다. 이미지 업로드는
    // 이 함수 호출 이전에 이미 완료되어 media_path로 전달되어야 하며,
    // 이 INSERT가 실패했을 때 방금 올린 Storage 파일을 보상 삭제하는 책임은
    // 이 함수가 아니라 다음 단계에서 만들 제출 오케스트레이터가 진다.
    async function createManagedImageArtwork(exhibitionId, input) {
        const client = getClient();
        if (!client) {
            return { ok: false, artwork: null, error: safeError('db_unavailable', '작품 등록 서비스를 사용할 수 없습니다.') };
        }

        if (!exhibitionId) {
            return { ok: false, artwork: null, error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, artwork: null, error: safeError('db_unavailable', '작품 등록 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, artwork: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, artwork: null, error: safeError('role_not_allowed', '작품 등록은 운영자 계정만 가능합니다.') };
        }

        const managedResult = await getMyManagedExhibitions();

        if (!managedResult.ok) {
            return { ok: false, artwork: null, error: managedResult.error };
        }

        const isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionId; });

        if (!isManaged) {
            return { ok: false, artwork: null, error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        // input을 그대로 스프레드하지 않고 화이트리스트 필드만 꺼낸다.
        const safeInput = input || {};
        const title = typeof safeInput.title === 'string' ? safeInput.title.trim() : '';
        const artistDisplayName = typeof safeInput.artist_display_name === 'string' ? safeInput.artist_display_name.trim() : '';
        const categoryId = typeof safeInput.category_id === 'string' ? safeInput.category_id : '';
        const descriptionTrimmed = typeof safeInput.description === 'string' ? safeInput.description.trim() : '';
        const consentConfirmed = safeInput.consent_confirmed === true;
        const mediaPath = typeof safeInput.media_path === 'string' ? safeInput.media_path : '';

        if (!title || title.length > 100) {
            return { ok: false, artwork: null, error: safeError('invalid_title', '작품명을 100자 이내로 입력해 주세요.') };
        }

        if (!artistDisplayName || artistDisplayName.length > 50) {
            return { ok: false, artwork: null, error: safeError('invalid_artist_name', '작가 표시명을 50자 이내로 입력해 주세요.') };
        }

        const categoriesResult = await getCategories();

        if (!categoriesResult.ok) {
            return { ok: false, artwork: null, error: categoriesResult.error };
        }

        const categoryExists = categoriesResult.categories.some(function (cat) { return cat.id === categoryId; });

        if (!categoryExists) {
            return { ok: false, artwork: null, error: safeError('invalid_category', '카테고리를 선택해 주세요.') };
        }

        if (descriptionTrimmed.length > 500) {
            return { ok: false, artwork: null, error: safeError('invalid_description', '작품 설명은 500자를 초과할 수 없습니다.') };
        }

        if (!consentConfirmed) {
            return { ok: false, artwork: null, error: safeError('consent_required', '전시 동의 확인이 필요합니다.') };
        }

        if (!isValidManagedImagePath(mediaPath, exhibitionId)) {
            return { ok: false, artwork: null, error: safeError('invalid_media_path', '이미지 경로 정보가 올바르지 않습니다.') };
        }

        const payload = {
            exhibition_id: exhibitionId,
            category_id: categoryId,
            title: title,
            media_type: 'image',
            thumbnail_url: mediaPath,
            media_url: mediaPath,
            artist_display_name: artistDisplayName,
            description: descriptionTrimmed.length > 0 ? descriptionTrimmed : null,
            status: 'pending',
            consent_confirmed: true,
            consent_scope: 'online_exhibition_confirmed_by_operator',
            submitted_by: context.userId
        };

        try {
            const { data, error } = await client
                .from('artworks')
                .insert(payload)
                .select('id, exhibition_id, category_id, title, media_type, artist_display_name, status, consent_confirmed, created_at')
                .single();

            if (error) {
                return { ok: false, artwork: null, error: safeError('artwork_insert_failed', '작품 등록에 실패했습니다.') };
            }

            return { ok: true, artwork: data, error: null };
        } catch (err) {
            return { ok: false, artwork: null, error: safeError('artwork_insert_failed', '작품 등록 중 오류가 발생했습니다.') };
        }
    }

    // 통합 작품 등록 - image/document/video 공용. 기존 createManagedArtwork(text)/
    // createManagedImageArtwork는 기존 데이터·화면 호환용으로 그대로 두고 이
    // 함수에서 대체하지 않는다.
    //
    // 이 함수도 storage-service.js를 직접 호출하지 않는다. 파일 업로드는 이
    // 함수 호출 이전에 이미 완료되어 media_path(영상은 thumbnail_path도 함께)로
    // 전달되어야 하며, 이 INSERT가 실패했을 때 방금 올린 Storage 파일을 보상
    // 삭제하는 책임은 이 함수가 아니라 호출자(제출 오케스트레이터)가 진다.
    async function createManagedUnifiedArtwork(exhibitionId, input) {
        const client = getClient();
        if (!client) {
            return { ok: false, artwork: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        // 1. exhibitionId UUID 형식
        if (!isValidUuid(exhibitionId)) {
            return { ok: false, artwork: null, error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        // 2. input 객체 여부
        if (!input || typeof input !== 'object') {
            return { ok: false, artwork: null, error: safeError('invalid_input', '입력값이 올바르지 않습니다.') };
        }

        // input을 그대로 스프레드하지 않고 화이트리스트 필드만 꺼낸다.
        const mediaType = typeof input.media_type === 'string' ? input.media_type : '';
        const title = typeof input.title === 'string' ? input.title.trim() : '';
        const artistDisplayName = typeof input.artist_display_name === 'string' ? input.artist_display_name.trim() : '';
        const categoryId = typeof input.category_id === 'string' ? input.category_id.trim() : '';
        const descriptionTrimmed = typeof input.description === 'string' ? input.description.trim() : '';
        const consentConfirmed = input.consent_confirmed === true;
        const mediaPath = typeof input.media_path === 'string' ? input.media_path : '';
        // video 전용 - image/document는 이 필드를 아예 보내지 않는다(무시됨).
        const thumbnailPath = typeof input.thumbnail_path === 'string' ? input.thumbnail_path : '';
        // video의 외부 링크 방식 전용 - image/document/직접 업로드 영상은
        // 이 필드를 아예 보내지 않는다(무시됨).
        const externalUrl = typeof input.external_url === 'string' ? input.external_url.trim() : '';

        // 3. media_type이 image/document/video인지 (text/audio/mixed는 차단)
        if (['image', 'document', 'video'].indexOf(mediaType) === -1) {
            return { ok: false, artwork: null, error: safeError('unsupported_media_type', '이미지, 문서 또는 영상 형식만 등록할 수 있습니다.') };
        }

        // 4. 작품명
        if (!title || title.length > 100) {
            return { ok: false, artwork: null, error: safeError('invalid_title', '작품명을 100자 이내로 입력해 주세요.') };
        }

        // 5. 작가 표시명
        if (!artistDisplayName || artistDisplayName.length > 50) {
            return { ok: false, artwork: null, error: safeError('invalid_artist_display_name', '작가 표시명을 50자 이내로 입력해 주세요.') };
        }

        // 6. 카테고리 (형식만, 실제 존재 여부는 13번에서 조회 확인)
        if (!categoryId) {
            return { ok: false, artwork: null, error: safeError('invalid_category', '카테고리를 선택해 주세요.') };
        }

        // 7. 작품 설명 (선택)
        if (descriptionTrimmed.length > 500) {
            return { ok: false, artwork: null, error: safeError('invalid_description', '작품 설명은 500자를 초과할 수 없습니다.') };
        }

        // 8. 전시 동의 - UI 체크박스를 우회하더라도 여기서 다시 한번 강제한다.
        if (!consentConfirmed) {
            return { ok: false, artwork: null, error: safeError('consent_required', '전시 동의 확인이 필요합니다.') };
        }

        // 9. media_path 필수 여부. video는 직접 업로드(media_path)와 외부
        //    링크(external_url) 중 정확히 하나만 제공돼야 한다. image/document는
        //    기존과 동일하게 media_path가 항상 필수다(형식 상세 검증은 14번에서).
        if (mediaType === 'video') {
            const hasMediaPath = mediaPath.length > 0;
            const hasExternalUrl = externalUrl.length > 0;

            if (hasMediaPath && hasExternalUrl) {
                return { ok: false, artwork: null, error: safeError('invalid_media_path', '영상은 직접 업로드 또는 외부 링크 중 하나만 등록할 수 있습니다.') };
            }
            if (!hasMediaPath && !hasExternalUrl) {
                return { ok: false, artwork: null, error: safeError('invalid_media_path', '영상 파일 또는 외부 링크 중 하나는 반드시 등록해야 합니다.') };
            }
        } else if (!mediaPath) {
            return { ok: false, artwork: null, error: safeError('invalid_media_path', '작품 파일 경로 정보가 올바르지 않습니다.') };
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, artwork: null, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        // 10. 로그인 상태
        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, artwork: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        // 11. 운영자 계정 확인
        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, artwork: null, error: safeError('role_not_allowed', '작품 등록은 운영자 계정만 가능합니다.') };
        }

        // 12. 담당 전시관 확인
        const managedResult = await getMyManagedExhibitions();

        if (!managedResult.ok) {
            return { ok: false, artwork: null, error: managedResult.error };
        }

        const isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionId; });

        if (!isManaged) {
            return { ok: false, artwork: null, error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        // 13. 카테고리 실제 존재 여부
        const categoriesResult = await getCategories();

        if (!categoriesResult.ok) {
            return { ok: false, artwork: null, error: categoriesResult.error };
        }

        const categoryExists = categoriesResult.categories.some(function (cat) { return cat.id === categoryId; });

        if (!categoryExists) {
            return { ok: false, artwork: null, error: safeError('invalid_category', '카테고리를 선택해 주세요.') };
        }

        // 14. media_path가 exhibitionId 폴더와 정확히 일치하는지 + media_type별 규칙
        //     image   : 기존 이미지 path(jpg/png/webp)만 허용, pdf 경로는 거부
        //     document: PDF path 또는 기존 이미지 path 모두 허용
        //     video(직접 업로드) : media_path는 반드시 .mp4, thumbnail_path는
        //               반드시 이미지 path이며 media_path와 서로 달라야 한다.
        //     video(외부 링크)   : media_path는 비워두고(위 9번에서 이미 확인),
        //               external_url이 HTTPS MP4 직접 링크 형식이어야 하며
        //               thumbnail_path는 여전히 필수(이미지 경로).
        const isImagePath = isValidManagedImagePath(mediaPath, exhibitionId);
        const isPdfPath = isValidManagedDocumentPdfPath(mediaPath, exhibitionId);

        let thumbnailUrlForPayload = null;
        let mediaUrlForPayload = null;
        let externalUrlForPayload = null;

        if (mediaType === 'image') {
            if (!isImagePath) {
                return { ok: false, artwork: null, error: safeError('invalid_media_path', '이미지 경로 정보가 올바르지 않습니다.') };
            }
            thumbnailUrlForPayload = mediaPath;
            mediaUrlForPayload = mediaPath;
        } else if (mediaType === 'document') {
            if (!isImagePath && !isPdfPath) {
                return { ok: false, artwork: null, error: safeError('invalid_media_path', '문서 경로 정보가 올바르지 않습니다.') };
            }
            thumbnailUrlForPayload = isImagePath ? mediaPath : null;
            mediaUrlForPayload = mediaPath;
        } else {
            // mediaType === 'video' - 썸네일은 방식과 무관하게 항상 필수.
            const isThumbnailImagePath = isValidManagedImagePath(thumbnailPath, exhibitionId);
            if (!isThumbnailImagePath) {
                return { ok: false, artwork: null, error: safeError('invalid_thumbnail_path', '썸네일 경로 정보가 올바르지 않습니다.') };
            }
            thumbnailUrlForPayload = thumbnailPath;

            if (mediaPath) {
                // 직접 업로드
                const isVideoPath = isValidManagedVideoPath(mediaPath, exhibitionId);
                if (!isVideoPath) {
                    return { ok: false, artwork: null, error: safeError('invalid_media_path', '영상 경로 정보가 올바르지 않습니다.') };
                }
                if (mediaPath === thumbnailPath) {
                    return { ok: false, artwork: null, error: safeError('invalid_media_path', '영상과 썸네일 경로는 서로 달라야 합니다.') };
                }
                mediaUrlForPayload = mediaPath;
                externalUrlForPayload = null;
            } else {
                // 외부 링크
                if (!isValidExternalVideoUrl(externalUrl)) {
                    return { ok: false, artwork: null, error: safeError('invalid_external_url', '외부 영상 링크 형식이 올바르지 않습니다.') };
                }
                mediaUrlForPayload = null;
                externalUrlForPayload = externalUrl;
            }
        }

        const payload = {
            exhibition_id: exhibitionId,
            category_id: categoryId,
            title: title,
            media_type: mediaType,
            artist_display_name: artistDisplayName,
            description: descriptionTrimmed.length > 0 ? descriptionTrimmed : null,
            thumbnail_url: thumbnailUrlForPayload,
            media_url: mediaUrlForPayload,
            external_url: externalUrlForPayload,
            status: 'pending',
            consent_confirmed: true,
            consent_scope: 'online_exhibition_confirmed_by_operator',
            submitted_by: context.userId
        };

        try {
            const { data, error } = await client
                .from('artworks')
                .insert(payload)
                .select('id, exhibition_id, category_id, title, media_type, artist_display_name, status, consent_confirmed, created_at')
                .single();

            if (error) {
                return { ok: false, artwork: null, error: safeError('artwork_create_failed', '작품 등록에 실패했습니다.') };
            }

            return { ok: true, artwork: data, error: null };
        } catch (err) {
            return { ok: false, artwork: null, error: safeError('unexpected_error', '작품 등록 중 오류가 발생했습니다.') };
        }
    }

    async function getPendingArtworksForAdmin() {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, artworks: [], error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, artworks: [], error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, artworks: [], error: safeError('role_not_allowed', '승인 대기 목록 조회는 관리자 계정만 가능합니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, artworks: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('artworks')
                .select(`
                    id,
                    exhibition_id,
                    category_id,
                    title,
                    media_type,
                    artist_display_name,
                    status,
                    consent_confirmed,
                    created_at,
                    thumbnail_url,
                    media_url,
                    categories (
                        id,
                        name
                    ),
                    exhibitions (
                        id,
                        title,
                        exhibition_type,
                        visibility,
                        is_demo
                    )
                `)
                .eq('status', 'pending')
                .order('created_at', { ascending: true });

            if (error) {
                return { ok: false, artworks: [], error: safeError('artworks_fetch_failed', '승인 대기 작품 목록을 불러오지 못했습니다.') };
            }

            return { ok: true, artworks: Array.isArray(data) ? data : [], error: null };
        } catch (err) {
            return { ok: false, artworks: [], error: safeError('unexpected_error', '승인 대기 작품 조회 중 오류가 발생했습니다.') };
        }
    }

    async function approveArtworkAsAdmin(artworkId) {
        if (!artworkId) {
            return { ok: false, error: safeError('invalid_artwork_id', '작품 정보가 올바르지 않습니다.') };
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, error: safeError('role_not_allowed', '작품 승인은 관리자 계정만 가능합니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { error } = await client.rpc('approve_artwork', { target_artwork_id: artworkId });

            if (error) {
                return { ok: false, error: safeError('artwork_approve_failed', error.message || '작품 승인에 실패했습니다.') };
            }

            return { ok: true, error: null };
        } catch (err) {
            return { ok: false, error: safeError('unexpected_error', '작품 승인 중 오류가 발생했습니다.') };
        }
    }

    async function rejectArtworkAsAdmin(artworkId, reason) {
        if (!artworkId) {
            return { ok: false, error: safeError('invalid_artwork_id', '작품 정보가 올바르지 않습니다.') };
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, error: safeError('role_not_allowed', '작품 반려는 관리자 계정만 가능합니다.') };
        }

        const trimmedReason = typeof reason === 'string' ? reason.trim() : '';

        if (!trimmedReason) {
            return { ok: false, error: safeError('reason_required', '반려 사유를 입력해 주세요.') };
        }

        if (trimmedReason.length > 500) {
            return { ok: false, error: safeError('reason_too_long', '반려 사유는 500자를 초과할 수 없습니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { error } = await client.rpc('reject_artwork', { target_artwork_id: artworkId, reason: trimmedReason });

            if (error) {
                return { ok: false, error: safeError('artwork_reject_failed', error.message || '작품 반려에 실패했습니다.') };
            }

            return { ok: true, error: null };
        } catch (err) {
            return { ok: false, error: safeError('unexpected_error', '작품 반려 중 오류가 발생했습니다.') };
        }
    }

    // 관리자용 - public/private/demo 여부와 무관하게 내부 전시관 전체를
    // 조회한다.
    async function getExhibitionsForAdmin() {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, exhibitions: [], error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, exhibitions: [], error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, exhibitions: [], error: safeError('role_not_allowed', '전시관 조회는 관리자 계정만 가능합니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, exhibitions: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('exhibitions')
                .select(`
                    id,
                    slug,
                    legacy_id,
                    title,
                    description,
                    tag,
                    organization_name,
                    cover_image_path,
                    exhibition_type,
                    operation_status,
                    visibility,
                    is_demo,
                    is_external,
                    allow_comments,
                    start_date,
                    end_date,
                    created_at,
                    updated_at
                `)
                .order('created_at', { ascending: false });

            if (error) {
                return { ok: false, exhibitions: [], error: safeError('exhibitions_fetch_failed', '전시관 목록을 불러오지 못했습니다.') };
            }

            return { ok: true, exhibitions: Array.isArray(data) ? data : [], error: null };
        } catch (err) {
            return { ok: false, exhibitions: [], error: safeError('unexpected_error', '전시관 조회 중 오류가 발생했습니다.') };
        }
    }

    // 관리자 전용 - 특정 전시관의 작품을 상태(pending/approved/rejected/hidden)
    // 구분 없이 전부 조회한다. getManagedArtworks()는 "담당 운영자인지" RLS를
    // 통과해야 하므로 관리자가 담당하지 않는 전시관에는 쓸 수 없고,
    // getPublicArtworksForExhibition()은 승인·공개·운영 중인 작품만 보여줘
    // 미리보기 목적에 맞지 않는다. artworks 테이블에는 이미 관리자 역할
    // 전체를 허용하는 SELECT RLS가 있다(getPendingArtworksForAdmin()이
    // 전시관 구분 없이 status='pending'만 걸고 조회 가능한 것으로 확인됨).
    // artist_age/submitted_by/approved_by/rejection_reason 등은 이 미리보기
    // 목적에 필요하지 않으므로 select에 넣지 않는다.
    async function getArtworksForAdminExhibition(exhibitionId) {
        if (!isValidUuid(exhibitionId)) {
            return { ok: false, artworks: [], error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, artworks: [], error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, artworks: [], error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, artworks: [], error: safeError('role_not_allowed', '작품 조회는 관리자 계정만 가능합니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, artworks: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('artworks')
                .select(`
                    id,
                    title,
                    media_type,
                    artist_display_name,
                    category_id,
                    thumbnail_url,
                    media_url,
                    description,
                    poem,
                    status,
                    consent_confirmed,
                    created_at,
                    categories (
                        name
                    )
                `)
                .eq('exhibition_id', exhibitionId)
                .order('created_at', { ascending: false });

            if (error) {
                return { ok: false, artworks: [], error: safeError('artworks_fetch_failed', '작품 목록을 불러오지 못했습니다.') };
            }

            const rows = Array.isArray(data) ? data : [];

            const artworks = rows.map(function (row) {
                return {
                    id: row.id,
                    title: row.title,
                    media_type: row.media_type,
                    artist_display_name: row.artist_display_name,
                    category_id: row.category_id,
                    thumbnail_url: row.thumbnail_url,
                    media_url: row.media_url,
                    description: row.description,
                    poem: row.poem,
                    status: row.status,
                    consent_confirmed: row.consent_confirmed,
                    created_at: row.created_at,
                    categories: row.categories
                };
            });

            return { ok: true, artworks: artworks, error: null };
        } catch (err) {
            return { ok: false, artworks: [], error: safeError('unexpected_error', '작품 조회 중 오류가 발생했습니다.') };
        }
    }

    // 관리자용 - 신규 내부 전시관을 생성한다. 생성 직후에는 항상
    // private/preparing/non-demo/internal로 고정한다(운영자에게 공개 전환
    // 권한을 주지 않는다는 원칙과 별개로, 이 함수 자체도 그 외 상태로는
    // 절대 만들지 않는다). input을 그대로 스프레드하지 않고 화이트리스트
    // 필드만 꺼내 검증한 뒤 payload를 내부에서 직접 구성한다.
    async function createExhibitionAsAdmin(input) {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, exhibition: null, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, exhibition: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, exhibition: null, error: safeError('role_not_allowed', '전시관 생성은 관리자 계정만 가능합니다.') };
        }

        if (!input || typeof input !== 'object') {
            return { ok: false, exhibition: null, error: safeError('invalid_input', '입력값이 올바르지 않습니다.') };
        }

        const title = typeof input.title === 'string' ? input.title.trim() : '';
        const descriptionTrimmed = typeof input.description === 'string' ? input.description.trim() : '';
        const tagTrimmed = typeof input.tag === 'string' ? input.tag.trim() : '';
        const organizationNameTrimmed = typeof input.organization_name === 'string' ? input.organization_name.trim() : '';
        const exhibitionType = typeof input.exhibition_type === 'string' ? input.exhibition_type : '';
        const allowComments = input.allow_comments === true;

        if (!title || title.length > 100) {
            return { ok: false, exhibition: null, error: safeError('invalid_title', '전시관 제목을 100자 이내로 입력해 주세요.') };
        }

        if (descriptionTrimmed.length > 1000) {
            return { ok: false, exhibition: null, error: safeError('invalid_description', '전시관 설명은 1000자를 초과할 수 없습니다.') };
        }

        if (tagTrimmed.length > 50) {
            return { ok: false, exhibition: null, error: safeError('invalid_tag', '태그는 50자를 초과할 수 없습니다.') };
        }

        if (organizationNameTrimmed.length > 100) {
            return { ok: false, exhibition: null, error: safeError('invalid_organization_name', '기관명은 100자를 초과할 수 없습니다.') };
        }

        if (['institution', 'instructor', 'personal'].indexOf(exhibitionType) === -1) {
            return { ok: false, exhibition: null, error: safeError('invalid_exhibition_type', '전시관 운영 형태를 선택해 주세요.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, exhibition: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        if (typeof crypto === 'undefined' || typeof crypto.randomUUID !== 'function') {
            return { ok: false, exhibition: null, error: safeError('client_unavailable', '이 브라우저에서는 전시관 생성을 사용할 수 없습니다.') };
        }

        function buildPayload() {
            return {
                slug: onhadaBuildExhibitionSlug(title),
                title: title,
                description: descriptionTrimmed.length > 0 ? descriptionTrimmed : null,
                tag: tagTrimmed.length > 0 ? tagTrimmed : null,
                organization_name: organizationNameTrimmed.length > 0 ? organizationNameTrimmed : null,
                exhibition_type: exhibitionType,
                allow_comments: allowComments,
                visibility: 'private',
                operation_status: 'preparing',
                is_demo: false,
                is_external: false,
                external_url: null,
                cover_image_path: null
            };
        }

        const selectFields = 'id, slug, title, description, tag, organization_name, exhibition_type, operation_status, visibility, is_demo, is_external, allow_comments, created_at';

        try {
            let payload = buildPayload();
            let insertResult = await client
                .from('exhibitions')
                .insert(payload)
                .select(selectFields)
                .single();

            if (insertResult.error && insertResult.error.code === '23505') {
                // slug 충돌 - 새 UUID 접미사로 딱 1회만 재시도한다. 무한 재시도 금지.
                payload = buildPayload();
                insertResult = await client
                    .from('exhibitions')
                    .insert(payload)
                    .select(selectFields)
                    .single();
            }

            if (insertResult.error) {
                return { ok: false, exhibition: null, error: safeError('exhibition_create_failed', '전시관 생성에 실패했습니다.') };
            }

            return { ok: true, exhibition: insertResult.data, error: null };
        } catch (err) {
            return { ok: false, exhibition: null, error: safeError('unexpected_error', '전시관 생성 중 오류가 발생했습니다.') };
        }
    }

    // 관리자용 - role IN ('pending','manager')인 프로필만 조회한다.
    // admin 계정은 이 필터 자체에 의해 목록에서 제외된다.
    async function getOperatorProfilesForAdmin() {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, profiles: [], error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, profiles: [], error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, profiles: [], error: safeError('role_not_allowed', '운영자 목록 조회는 관리자 계정만 가능합니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, profiles: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('profiles')
                .select('id, display_name, role, manager_type, created_at')
                .in('role', ['pending', 'manager'])
                .order('created_at', { ascending: false });

            if (error) {
                return { ok: false, profiles: [], error: safeError('operator_profiles_fetch_failed', '운영자 목록을 불러오지 못했습니다.') };
            }

            return { ok: true, profiles: Array.isArray(data) ? data : [], error: null };
        } catch (err) {
            return { ok: false, profiles: [], error: safeError('unexpected_error', '운영자 목록 조회 중 오류가 발생했습니다.') };
        }
    }

    // 관리자용 - pending 프로필 1건을 manager로 승격한다. role과
    // manager_type을 한 UPDATE 문으로 함께 바꾸고, WHERE 절에도
    // role='pending'을 다시 걸어 그 사이 상태가 바뀐 프로필을 실수로
    // 덮어쓰지 않게 한다(사전 조회 확인 + UPDATE 자체 조건의 이중 방어).
    async function approvePendingProfileAsManager(profileId, managerType) {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, profile: null, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, profile: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, profile: null, error: safeError('role_not_allowed', '운영자 승인은 관리자 계정만 가능합니다.') };
        }

        if (!isValidUuid(profileId)) {
            return { ok: false, profile: null, error: safeError('invalid_profile_id', '프로필 정보가 올바르지 않습니다.') };
        }

        if (['instructor', 'institution_staff', 'individual_creator'].indexOf(managerType) === -1) {
            return { ok: false, profile: null, error: safeError('invalid_manager_type', '운영자 유형을 올바르게 선택해 주세요.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, profile: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data: existing, error: fetchError } = await client
                .from('profiles')
                .select('id, role')
                .eq('id', profileId)
                .maybeSingle();

            if (fetchError) {
                return { ok: false, profile: null, error: safeError('manager_approval_failed', '대상 프로필을 확인하지 못했습니다.') };
            }

            if (!existing) {
                return { ok: false, profile: null, error: safeError('profile_not_found', '대상 프로필을 찾을 수 없습니다.') };
            }

            if (existing.role !== 'pending') {
                return { ok: false, profile: null, error: safeError('profile_not_pending', '승인 대기 상태의 프로필만 운영자로 전환할 수 있습니다.') };
            }

            const { data, error } = await client
                .from('profiles')
                .update({ role: 'manager', manager_type: managerType })
                .eq('id', profileId)
                .eq('role', 'pending')
                .select('id, display_name, role, manager_type, created_at')
                .single();

            if (error) {
                return { ok: false, profile: null, error: safeError('manager_approval_failed', '운영자 승인에 실패했습니다.') };
            }

            return { ok: true, profile: data, error: null };
        } catch (err) {
            return { ok: false, profile: null, error: safeError('unexpected_error', '운영자 승인 중 오류가 발생했습니다.') };
        }
    }

    // 관리자용 - 내부 전시관에 manager 프로필 1명을 배정한다.
    async function assignExhibitionManager(exhibitionId, profileId) {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, mapping: null, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, mapping: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, mapping: null, error: safeError('role_not_allowed', '전시관 배정은 관리자 계정만 가능합니다.') };
        }

        if (!isValidUuid(exhibitionId)) {
            return { ok: false, mapping: null, error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        if (!isValidUuid(profileId)) {
            return { ok: false, mapping: null, error: safeError('invalid_profile_id', '프로필 정보가 올바르지 않습니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, mapping: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data: exhibition, error: exError } = await client
                .from('exhibitions')
                .select('id, title, is_external')
                .eq('id', exhibitionId)
                .maybeSingle();

            if (exError) {
                return { ok: false, mapping: null, error: safeError('manager_assignment_failed', '전시관 정보를 확인하지 못했습니다.') };
            }

            if (!exhibition) {
                return { ok: false, mapping: null, error: safeError('exhibition_not_found', '전시관을 찾을 수 없습니다.') };
            }

            if (exhibition.is_external) {
                return { ok: false, mapping: null, error: safeError('external_exhibition_not_assignable', '외부 연동 전시관에는 운영자를 배정할 수 없습니다.') };
            }

            const { data: profile, error: profileError } = await client
                .from('profiles')
                .select('id, display_name, role, manager_type')
                .eq('id', profileId)
                .maybeSingle();

            if (profileError) {
                return { ok: false, mapping: null, error: safeError('manager_assignment_failed', '프로필 정보를 확인하지 못했습니다.') };
            }

            if (!profile) {
                return { ok: false, mapping: null, error: safeError('profile_not_found', '대상 프로필을 찾을 수 없습니다.') };
            }

            if (profile.role !== 'manager') {
                return { ok: false, mapping: null, error: safeError('profile_not_manager', '운영자 계정만 전시관에 배정할 수 있습니다.') };
            }

            // 반환값에는 mapping id 등 최소 필드만 담는다. 실제 화면(app.html)에는
            // 이 UUID를 그대로 표시하지 않고, 배정 성공 여부와 운영자 표시명 등
            // 안전한 정보만 사용할 예정이다.
            const { data, error } = await client
                .from('exhibition_managers')
                .insert({ exhibition_id: exhibitionId, profile_id: profileId })
                .select('id, exhibition_id, profile_id, created_at')
                .single();

            if (error) {
                if (error.code === '23505') {
                    return { ok: false, mapping: null, error: safeError('already_assigned', '이미 배정된 운영자입니다.') };
                }
                return { ok: false, mapping: null, error: safeError('manager_assignment_failed', '전시관 배정에 실패했습니다.') };
            }

            return { ok: true, mapping: data, error: null };
        } catch (err) {
            return { ok: false, mapping: null, error: safeError('unexpected_error', '전시관 배정 중 오류가 발생했습니다.') };
        }
    }

    // 관리자용 - 특정 전시관의 담당 운영자 목록을 조회한다. profiles를
    // FK 임베드로 함께 가져와 평탄화한다.
    async function getExhibitionManagers(exhibitionId) {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, managers: [], error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, managers: [], error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, managers: [], error: safeError('role_not_allowed', '담당 운영자 조회는 관리자 계정만 가능합니다.') };
        }

        if (!isValidUuid(exhibitionId)) {
            return { ok: false, managers: [], error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, managers: [], error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client
                .from('exhibition_managers')
                .select(`
                    id,
                    profile_id,
                    created_at,
                    profiles (
                        display_name,
                        role,
                        manager_type,
                        created_at
                    )
                `)
                .eq('exhibition_id', exhibitionId)
                .order('created_at', { ascending: true });

            if (error) {
                return { ok: false, managers: [], error: safeError('exhibition_managers_fetch_failed', '담당 운영자 목록을 불러오지 못했습니다.') };
            }

            const rows = Array.isArray(data) ? data : [];

            const managers = rows
                .filter(function (row) { return !!row.profiles; })
                .map(function (row) {
                    return {
                        mappingId: row.id,
                        profileId: row.profile_id,
                        displayName: row.profiles.display_name,
                        role: row.profiles.role,
                        managerType: row.profiles.manager_type,
                        profileCreatedAt: row.profiles.created_at,
                        assignedAt: row.created_at
                    };
                });

            return { ok: true, managers: managers, error: null };
        } catch (err) {
            return { ok: false, managers: [], error: safeError('unexpected_error', '담당 운영자 조회 중 오류가 발생했습니다.') };
        }
    }

    // 관리자용 - exhibition_managers 매핑 1건만 삭제한다. profiles 행이나
    // 다른 매핑에는 전혀 손대지 않는다(운영자 계정/역할은 그대로 유지).
    async function unassignExhibitionManager(mappingId) {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, removed: false, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, removed: false, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, removed: false, error: safeError('role_not_allowed', '운영자 배정 해제는 관리자 계정만 가능합니다.') };
        }

        if (!isValidUuid(mappingId)) {
            return { ok: false, removed: false, error: safeError('invalid_mapping_id', '배정 정보가 올바르지 않습니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, removed: false, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data: existing, error: fetchError } = await client
                .from('exhibition_managers')
                .select('id')
                .eq('id', mappingId)
                .maybeSingle();

            if (fetchError) {
                return { ok: false, removed: false, error: safeError('manager_unassignment_failed', '배정 정보를 확인하지 못했습니다.') };
            }

            if (!existing) {
                return { ok: false, removed: false, error: safeError('mapping_not_found', '배정 정보를 찾을 수 없습니다.') };
            }

            const { error } = await client
                .from('exhibition_managers')
                .delete()
                .eq('id', mappingId);

            if (error) {
                return { ok: false, removed: false, error: safeError('manager_unassignment_failed', '운영자 배정 해제에 실패했습니다.') };
            }

            return { ok: true, removed: true, error: null };
        } catch (err) {
            return { ok: false, removed: false, error: safeError('unexpected_error', '운영자 배정 해제 중 오류가 발생했습니다.') };
        }
    }

    // manager 본인 작품 수정 - 08_manager_own_artwork_workflow.sql의
    // update_own_artwork RPC를 호출한다. exhibitionId는 서버에 보내지 않고
    // (RPC는 exhibition_id를 파라미터로 받지 않는다) 오직 이 함수 내부에서
    // media_url/thumbnail_url 경로가 그 전시관 폴더와 일치하는지 검증하는
    // 용도로만 쓴다. input은 그대로 스프레드하지 않고 화이트리스트 필드만
    // 꺼내며, exhibition_id/submitted_by/status/approved_by 등은 애초에
    // 읽지 않는다(실제 소유권·상태 검증은 RPC 내부가 최종 방어선).
    async function updateOwnArtworkAsManager(exhibitionId, artworkId, input) {
        const client = getClient();
        if (!client) {
            return { ok: false, cleanup: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        // 1. exhibitionId UUID 형식
        if (!isValidUuid(exhibitionId)) {
            return { ok: false, cleanup: null, error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        // 2. artworkId UUID 형식
        if (!isValidUuid(artworkId)) {
            return { ok: false, cleanup: null, error: safeError('invalid_artwork_id', '작품 정보가 올바르지 않습니다.') };
        }

        // 3. input 객체 여부
        if (!input || typeof input !== 'object') {
            return { ok: false, cleanup: null, error: safeError('invalid_input', '입력값이 올바르지 않습니다.') };
        }

        // input을 그대로 스프레드하지 않고 화이트리스트 필드만 꺼낸다.
        const mediaType = typeof input.media_type === 'string' ? input.media_type : '';
        const title = typeof input.title === 'string' ? input.title.trim() : '';
        const artistDisplayName = typeof input.artist_display_name === 'string' ? input.artist_display_name.trim() : '';
        const categoryId = typeof input.category_id === 'string' ? input.category_id.trim() : '';
        const descriptionTrimmed = typeof input.description === 'string' ? input.description.trim() : '';
        const consentConfirmed = input.consent_confirmed === true;
        const mediaUrl = typeof input.media_url === 'string' ? input.media_url : '';
        const thumbnailUrl = input.thumbnail_url;

        // 4. media_type이 image 또는 document인지 (video/text/audio/mixed는 차단)
        if (['image', 'document'].indexOf(mediaType) === -1) {
            return { ok: false, cleanup: null, error: safeError('unsupported_media_type', '이미지 또는 문서 형식만 등록할 수 있습니다.') };
        }

        // 5. 작품명
        if (!title || title.length > 100) {
            return { ok: false, cleanup: null, error: safeError('invalid_title', '작품명을 100자 이내로 입력해 주세요.') };
        }

        // 6. 작가 표시명
        if (!artistDisplayName || artistDisplayName.length > 50) {
            return { ok: false, cleanup: null, error: safeError('invalid_artist_display_name', '작가 표시명을 50자 이내로 입력해 주세요.') };
        }

        // 7. 카테고리 (빈 값만 차단, 실제 존재 여부는 RPC 내부에서 재검증)
        if (!categoryId) {
            return { ok: false, cleanup: null, error: safeError('invalid_category', '카테고리를 선택해 주세요.') };
        }

        // 8. 작품 설명 (선택)
        if (descriptionTrimmed.length > 500) {
            return { ok: false, cleanup: null, error: safeError('invalid_description', '작품 설명은 500자를 초과할 수 없습니다.') };
        }

        // 9. 전시 동의 - UI 체크박스를 우회하더라도 여기서 다시 한번 강제한다.
        if (!consentConfirmed) {
            return { ok: false, cleanup: null, error: safeError('consent_required', '전시 동의 확인이 필요합니다.') };
        }

        // 10. media_url NULL/빈 문자열 차단
        if (!mediaUrl) {
            return { ok: false, cleanup: null, error: safeError('invalid_media_path', '작품 파일 경로 정보가 올바르지 않습니다.') };
        }

        // 11. media_url이 exhibitionId 폴더와 정확히 일치하는지 + media_type별
        //     thumbnail_url 규칙(기존 isValidManagedImagePath/
        //     isValidManagedDocumentPdfPath를 그대로 재사용, 본문은 건드리지 않음).
        const isImagePath = isValidManagedImagePath(mediaUrl, exhibitionId);
        const isPdfPath = isValidManagedDocumentPdfPath(mediaUrl, exhibitionId);

        if (mediaType === 'image') {
            if (!isImagePath) {
                return { ok: false, cleanup: null, error: safeError('invalid_media_path', '이미지 경로 정보가 올바르지 않습니다.') };
            }
            if (thumbnailUrl !== mediaUrl) {
                return { ok: false, cleanup: null, error: safeError('invalid_media_path', '이미지 경로 정보가 올바르지 않습니다.') };
            }
        } else {
            // mediaType === 'document'
            if (isPdfPath) {
                if (thumbnailUrl !== null) {
                    return { ok: false, cleanup: null, error: safeError('invalid_media_path', '문서 경로 정보가 올바르지 않습니다.') };
                }
            } else if (isImagePath) {
                if (thumbnailUrl !== mediaUrl) {
                    return { ok: false, cleanup: null, error: safeError('invalid_media_path', '문서 경로 정보가 올바르지 않습니다.') };
                }
            } else {
                return { ok: false, cleanup: null, error: safeError('invalid_media_path', '문서 경로 정보가 올바르지 않습니다.') };
            }
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, cleanup: null, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        // 12. 로그인 상태
        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, cleanup: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        // 13. 운영자 계정 확인
        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, cleanup: null, error: safeError('role_not_allowed', '작품 수정은 운영자 계정만 가능합니다.') };
        }

        try {
            const { data, error } = await client.rpc('update_own_artwork', {
                target_artwork_id: artworkId,
                p_title: title,
                p_artist_display_name: artistDisplayName,
                p_category_id: categoryId,
                p_description: descriptionTrimmed.length > 0 ? descriptionTrimmed : null,
                p_consent_confirmed: true,
                p_media_url: mediaUrl,
                p_thumbnail_url: thumbnailUrl,
                p_media_type: mediaType
            });

            if (error) {
                return { ok: false, cleanup: null, error: safeError('artwork_update_failed', error.message || '작품 수정에 실패했습니다.') };
            }

            // update_own_artwork는 RETURNS TABLE이므로 data는 배열이다.
            // 정확히 1행이 아니면 안전 실패로 처리한다.
            if (!Array.isArray(data) || data.length !== 1) {
                return { ok: false, cleanup: null, error: safeError('artwork_update_failed', '작품 수정에 실패했습니다.') };
            }

            const row = data[0];

            // previousMediaUrl/previousThumbnailUrl은 다음 단계(app.html)의
            // Storage 보상 정리 전용 내부 데이터다. DOM/console/사용자 메시지에
            // 절대 출력하지 않는다.
            return {
                ok: true,
                cleanup: {
                    previousMediaUrl: typeof row.previous_media_url === 'string' ? row.previous_media_url : null,
                    previousThumbnailUrl: typeof row.previous_thumbnail_url === 'string' ? row.previous_thumbnail_url : null
                },
                error: null
            };
        } catch (err) {
            return { ok: false, cleanup: null, error: safeError('unexpected_error', '작품 수정 중 오류가 발생했습니다.') };
        }
    }

    // manager 본인 작품 자가 승인 - approve_own_artwork RPC를 호출한다.
    async function approveOwnArtworkAsManager(artworkId) {
        if (!isValidUuid(artworkId)) {
            return { ok: false, error: safeError('invalid_artwork_id', '작품 정보가 올바르지 않습니다.') };
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, error: safeError('role_not_allowed', '작품 승인은 운영자 계정만 가능합니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { error } = await client.rpc('approve_own_artwork', { artwork_id: artworkId });

            if (error) {
                return { ok: false, error: safeError('artwork_approve_failed', error.message || '작품 승인에 실패했습니다.') };
            }

            return { ok: true, error: null };
        } catch (err) {
            return { ok: false, error: safeError('unexpected_error', '작품 승인 중 오류가 발생했습니다.') };
        }
    }

    // manager 본인 작품 영구 삭제 - delete_own_artwork RPC를 호출한다.
    // 이 함수는 DB 삭제만 담당하고 Storage remove 함수는 호출하지 않는다
    // (Storage 보상 정리는 이 함수가 반환한 cleanup을 이용해 다음 단계
    // app.html에서 수행한다).
    async function deleteOwnArtworkAsManager(artworkId) {
        if (!isValidUuid(artworkId)) {
            return { ok: false, cleanup: null, error: safeError('invalid_artwork_id', '작품 정보가 올바르지 않습니다.') };
        }

        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, cleanup: null, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, cleanup: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, cleanup: null, error: safeError('role_not_allowed', '작품 삭제는 운영자 계정만 가능합니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, cleanup: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client.rpc('delete_own_artwork', { artwork_id: artworkId });

            if (error) {
                return { ok: false, cleanup: null, error: safeError('artwork_delete_failed', error.message || '작품 삭제에 실패했습니다.') };
            }

            // delete_own_artwork도 RETURNS TABLE이므로 data는 배열이다.
            // 정확히 1행이 아니면 안전 실패로 처리한다.
            if (!Array.isArray(data) || data.length !== 1) {
                return { ok: false, cleanup: null, error: safeError('artwork_delete_failed', '작품 삭제에 실패했습니다.') };
            }

            const row = data[0];
            const mediaType = typeof row.removed_media_type === 'string' ? row.removed_media_type : '';

            if (['image', 'document'].indexOf(mediaType) === -1) {
                return { ok: false, cleanup: null, error: safeError('artwork_delete_failed', '작품 삭제에 실패했습니다.') };
            }

            const mediaUrl = row.removed_media_url === null ? null : (typeof row.removed_media_url === 'string' ? row.removed_media_url : undefined);
            const thumbnailUrl = row.removed_thumbnail_url === null ? null : (typeof row.removed_thumbnail_url === 'string' ? row.removed_thumbnail_url : undefined);

            // 반환 경로는 null 또는 문자열만 허용한다. 그 외 타입이면 안전 실패로 처리한다.
            if (mediaUrl === undefined || thumbnailUrl === undefined) {
                return { ok: false, cleanup: null, error: safeError('artwork_delete_failed', '작품 삭제에 실패했습니다.') };
            }

            // cleanup은 다음 단계(app.html)의 Storage 보상 정리 전용 내부 데이터다.
            // DOM/console/사용자 메시지에 절대 출력하지 않는다.
            return {
                ok: true,
                cleanup: {
                    mediaType: mediaType,
                    mediaUrl: mediaUrl,
                    thumbnailUrl: thumbnailUrl
                },
                error: null
            };
        } catch (err) {
            return { ok: false, cleanup: null, error: safeError('unexpected_error', '작품 삭제 중 오류가 발생했습니다.') };
        }
    }

    // 관리자 전용 - 전시관을 정확히 두 상태 조합 사이에서만 전환한다.
    //   공개하기: visibility='public',  operation_status='operating'  (직전 상태가 private+preparing일 때만)
    //   비공개 전환: visibility='private', operation_status='preparing' (직전 상태가 public+operating일 때만)
    // 신규 SQL/RPC를 만들지 않는다 - 기존 exhibitions_update_admin RLS
    // (USING/WITH CHECK 모두 is_admin() 전용)와 GRANT INSERT/UPDATE/DELETE ON
    // exhibitions TO authenticated를 그대로 재사용한다. exhibitions에는
    // manager용 UPDATE 정책이 애초에 존재하지 않으므로(SELECT만 있음)
    // manager 세션은 이 UPDATE 시도 자체가 RLS에서 차단된다 - 아래
    // context.profile.role==='admin' 검사는 그 앞단의 UX 방어선일 뿐이다.
    async function setExhibitionPublicationAsAdmin(exhibitionId, shouldPublish) {
        const auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, exhibition: null, error: safeError('auth_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        const context = await auth.getCurrentUserContext();

        // 1~2. 로그인 상태
        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, exhibition: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        // 3. 관리자 계정 확인
        if (!context.profile || context.profile.role !== 'admin') {
            return { ok: false, exhibition: null, error: safeError('role_not_allowed', '전시관 공개 상태 변경은 관리자 계정만 가능합니다.') };
        }

        // 4. exhibitionId UUID 형식
        if (!isValidUuid(exhibitionId)) {
            return { ok: false, exhibition: null, error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        // 5. shouldPublish 타입이 정확히 boolean인지(문자열 "true" 등은 차단)
        if (typeof shouldPublish !== 'boolean') {
            return { ok: false, exhibition: null, error: safeError('invalid_publication_mode', '요청 값이 올바르지 않습니다.') };
        }

        const client = getClient();
        if (!client) {
            return { ok: false, exhibition: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            // 대상 전시관을 최소 필드로 재조회한다.
            const { data: current, error: fetchError } = await client
                .from('exhibitions')
                .select('id, is_external, visibility, operation_status')
                .eq('id', exhibitionId)
                .maybeSingle();

            if (fetchError) {
                return { ok: false, exhibition: null, error: safeError('exhibition_publication_failed', '전시관 정보를 확인하지 못했습니다.') };
            }

            if (!current) {
                return { ok: false, exhibition: null, error: safeError('exhibition_not_found', '전시관을 찾을 수 없습니다.') };
            }

            if (current.is_external === true) {
                return { ok: false, exhibition: null, error: safeError('external_exhibition_not_publishable', '외부 연동 전시관은 공개 상태를 변경할 수 없습니다.') };
            }

            const previousVisibility = current.visibility;
            const previousOperationStatus = current.operation_status;

            // 정확한 두 상태 조합만 서로 전환한다. unlisted/beta/ended나
            // 서로 불일치하는 조합(예: public+preparing)은 전부 차단한다.
            if (shouldPublish) {
                if (previousVisibility !== 'private' || previousOperationStatus !== 'preparing') {
                    return { ok: false, exhibition: null, error: safeError('invalid_exhibition_state', '현재 상태에서는 공개로 전환할 수 없습니다.') };
                }
            } else {
                if (previousVisibility !== 'public' || previousOperationStatus !== 'operating') {
                    return { ok: false, exhibition: null, error: safeError('invalid_exhibition_state', '현재 상태에서는 비공개로 전환할 수 없습니다.') };
                }
            }

            // input을 그대로 스프레드하지 않고 payload를 내부에서 직접 구성한다.
            const payload = shouldPublish
                ? { visibility: 'public', operation_status: 'operating' }
                : { visibility: 'private', operation_status: 'preparing' };

            // 경쟁 상태 방지를 위해 재조회한 기존 값을 WHERE 조건에 그대로
            // 재적용한다 - 조회와 UPDATE 사이에 다른 요청이 먼저 상태를
            // 바꿨다면 이 UPDATE는 0행을 갱신하고 끝난다(아래에서 안전 처리).
            const { data: updatedRows, error: updateError } = await client
                .from('exhibitions')
                .update(payload)
                .eq('id', exhibitionId)
                .eq('is_external', false)
                .eq('visibility', previousVisibility)
                .eq('operation_status', previousOperationStatus)
                .select('id, visibility, operation_status, updated_at');

            if (updateError) {
                return { ok: false, exhibition: null, error: safeError('exhibition_publication_failed', '전시관 공개 상태 변경에 실패했습니다.') };
            }

            const rows = Array.isArray(updatedRows) ? updatedRows : [];

            if (rows.length !== 1) {
                // 0행(다른 요청이 먼저 상태를 바꿈) 또는 예상 밖의 다중 행 모두
                // 성공으로 취급하지 않고 안전하게 상태 변경 오류로 처리한다.
                return { ok: false, exhibition: null, error: safeError('publication_state_changed', '전시관 상태가 변경되어 요청을 처리할 수 없습니다.') };
            }

            // exhibition.id에는 UUID가 담기지만 이 반환값은 내부 데이터 용도다.
            // 이후 UI 단계에서도 이 값을 DOM이나 console에 그대로 출력하지 않는다.
            return { ok: true, exhibition: rows[0], error: null };
        } catch (err) {
            return { ok: false, exhibition: null, error: safeError('unexpected_error', '전시관 공개 상태 변경 중 오류가 발생했습니다.') };
        }
    }

    window.ONHADA_BACKEND.db = {
        getMyManagedExhibitions: getMyManagedExhibitions,
        getManagedArtworks: getManagedArtworks,
        getCategories: getCategories,
        getPublicExhibitions: getPublicExhibitions,
        getPublicArtworksForExhibition: getPublicArtworksForExhibition,
        createManagedArtwork: createManagedArtwork,
        createManagedImageArtwork: createManagedImageArtwork,
        createManagedUnifiedArtwork: createManagedUnifiedArtwork,
        getPendingArtworksForAdmin: getPendingArtworksForAdmin,
        approveArtworkAsAdmin: approveArtworkAsAdmin,
        rejectArtworkAsAdmin: rejectArtworkAsAdmin,
        getExhibitionsForAdmin: getExhibitionsForAdmin,
        getArtworksForAdminExhibition: getArtworksForAdminExhibition,
        createExhibitionAsAdmin: createExhibitionAsAdmin,
        getOperatorProfilesForAdmin: getOperatorProfilesForAdmin,
        approvePendingProfileAsManager: approvePendingProfileAsManager,
        assignExhibitionManager: assignExhibitionManager,
        getExhibitionManagers: getExhibitionManagers,
        unassignExhibitionManager: unassignExhibitionManager,
        updateOwnArtworkAsManager: updateOwnArtworkAsManager,
        approveOwnArtworkAsManager: approveOwnArtworkAsManager,
        deleteOwnArtworkAsManager: deleteOwnArtworkAsManager,
        setExhibitionPublicationAsAdmin: setExhibitionPublicationAsAdmin
    };
})();
