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

    window.ONHADA_BACKEND.db = {
        getMyManagedExhibitions: getMyManagedExhibitions
    };
})();
