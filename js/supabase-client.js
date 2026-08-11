(function () {
    window.ONHADA_BACKEND = window.ONHADA_BACKEND || {};

    var PROJECT_URL = 'https://rfxarolwxkmlbgnjrjhl.supabase.co';
    var PUBLISHABLE_KEY = 'sb_publishable_rCqC1woOIdlo7qQQcQkWzA_CFEJBUUe';

    try {
        if (!window.supabase || typeof window.supabase.createClient !== 'function') {
            throw new Error('Supabase SDK를 불러오지 못했습니다.');
        }

        window.ONHADA_BACKEND.client = window.supabase.createClient(PROJECT_URL, PUBLISHABLE_KEY);
        window.ONHADA_BACKEND.ready = true;
    } catch (error) {
        window.ONHADA_BACKEND.client = null;
        window.ONHADA_BACKEND.ready = false;
        console.error('[ONHADA] Supabase 초기화 실패:', error);
    }
})();
