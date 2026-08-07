(function () {
    window.ONHADA_BACKEND = window.ONHADA_BACKEND || {};

    function getClient() {
        return window.ONHADA_BACKEND && window.ONHADA_BACKEND.client;
    }

    function safeError(code, message) {
        return { code: code, message: message };
    }

    function isAllowedRole(role) {
        return role === 'admin' || role === 'manager';
    }

    async function fetchOwnProfile(client, userId) {
        try {
            const { data, error } = await client
                .from('profiles')
                .select('id, display_name, role, manager_type')
                .eq('id', userId)
                .maybeSingle();

            if (error) {
                return { profile: null, error: safeError('profile_fetch_failed', '프로필 정보를 불러오지 못했습니다.') };
            }

            return { profile: data || null, error: null };
        } catch (err) {
            return { profile: null, error: safeError('unexpected_error', '프로필 조회 중 오류가 발생했습니다.') };
        }
    }

    async function signIn(email, password) {
        const client = getClient();
        if (!client) {
            return { success: false, userId: null, profile: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client.auth.signInWithPassword({
                email: email,
                password: password
            });

            if (error) {
                return { success: false, userId: null, profile: null, error: safeError('sign_in_failed', '이메일 또는 비밀번호가 올바르지 않습니다.') };
            }

            const userId = data && data.user ? data.user.id : null;
            if (!userId) {
                return { success: false, userId: null, profile: null, error: safeError('sign_in_failed', '로그인에 실패했습니다.') };
            }

            const profileResult = await fetchOwnProfile(client, userId);

            if (profileResult.error) {
                await client.auth.signOut({ scope: 'local' });
                return { success: false, userId: null, profile: null, error: profileResult.error };
            }

            if (!profileResult.profile || !isAllowedRole(profileResult.profile.role)) {
                await client.auth.signOut({ scope: 'local' });
                return {
                    success: false,
                    userId: null,
                    profile: null,
                    error: safeError('role_not_allowed', '아직 승인되지 않은 계정입니다. 관리자 승인을 기다려 주세요.')
                };
            }

            return {
                success: true,
                userId: userId,
                profile: profileResult.profile,
                error: null
            };
        } catch (err) {
            return { success: false, userId: null, profile: null, error: safeError('unexpected_error', '로그인 중 오류가 발생했습니다.') };
        }
    }

    async function signOut() {
        const client = getClient();
        if (!client) {
            return { success: false, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { error } = await client.auth.signOut({ scope: 'local' });

            if (error) {
                return { success: false, error: safeError('sign_out_failed', '로그아웃 중 오류가 발생했습니다.') };
            }

            return { success: true, error: null };
        } catch (err) {
            return { success: false, error: safeError('unexpected_error', '로그아웃 중 오류가 발생했습니다.') };
        }
    }

    async function getSession() {
        const client = getClient();
        if (!client) {
            return { hasSession: false, userId: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        try {
            const { data, error } = await client.auth.getSession();

            if (error) {
                return { hasSession: false, userId: null, error: safeError('session_fetch_failed', '세션 정보를 불러오지 못했습니다.') };
            }

            const session = data ? data.session : null;
            if (!session || !session.user) {
                return { hasSession: false, userId: null, error: null };
            }

            return { hasSession: true, userId: session.user.id, error: null };
        } catch (err) {
            return { hasSession: false, userId: null, error: safeError('unexpected_error', '세션 확인 중 오류가 발생했습니다.') };
        }
    }

    async function getCurrentUserContext() {
        const session = await getSession();

        if (session.error) {
            return { signedIn: false, userId: null, profile: null, error: session.error };
        }

        if (!session.hasSession || !session.userId) {
            return { signedIn: false, userId: null, profile: null, error: null };
        }

        const client = getClient();
        if (!client) {
            return { signedIn: false, userId: null, profile: null, error: safeError('client_unavailable', 'Supabase 클라이언트를 사용할 수 없습니다.') };
        }

        const profileResult = await fetchOwnProfile(client, session.userId);

        if (profileResult.error) {
            return { signedIn: false, userId: null, profile: null, error: profileResult.error };
        }

        if (!profileResult.profile || !isAllowedRole(profileResult.profile.role)) {
            return { signedIn: false, userId: null, profile: null, error: null };
        }

        return { signedIn: true, userId: session.userId, profile: profileResult.profile, error: null };
    }

    function onAuthStateChange(callback) {
        const client = getClient();
        const noop = { unsubscribe: function () {} };

        if (!client || typeof callback !== 'function') {
            return noop;
        }

        try {
            const { data } = client.auth.onAuthStateChange((event, session) => {
                callback({
                    event: event,
                    hasUser: !!(session && session.user)
                });
            });

            if (data && data.subscription && typeof data.subscription.unsubscribe === 'function') {
                return data.subscription;
            }

            return noop;
        } catch (err) {
            console.error('[ONHADA] 인증 상태 구독 등록 실패');
            return noop;
        }
    }

    window.ONHADA_BACKEND.auth = {
        signIn: signIn,
        signOut: signOut,
        getSession: getSession,
        getCurrentUserContext: getCurrentUserContext,
        onAuthStateChange: onAuthStateChange
    };
})();
