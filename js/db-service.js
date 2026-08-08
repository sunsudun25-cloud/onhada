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
                    title,
                    category_id,
                    media_type,
                    artist_display_name,
                    status,
                    consent_confirmed,
                    created_at,
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

    window.ONHADA_BACKEND.db = {
        getMyManagedExhibitions: getMyManagedExhibitions,
        getManagedArtworks: getManagedArtworks,
        getCategories: getCategories,
        createManagedArtwork: createManagedArtwork
    };
})();
