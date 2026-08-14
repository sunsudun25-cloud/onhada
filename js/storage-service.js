(function () {
    window.ONHADA_BACKEND = window.ONHADA_BACKEND || {};

    var MAX_FILE_SIZE = 5 * 1024 * 1024;
    var MAX_DIMENSION = 4096;
    var MAX_SOURCE_PIXELS = 50 * 1000 * 1000; // 디코딩 단계 메모리 폭탄 방지용 상한(약 50MP)
    var JPEG_WEBP_QUALITY = 0.9;

    var ALLOWED_MIME_EXT = {
        'image/jpeg': 'jpg',
        'image/png': 'png',
        'image/webp': 'webp'
    };

    var UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    var ASSET_FILE_NAME_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$/i;

    function getClient() {
        return window.ONHADA_BACKEND && window.ONHADA_BACKEND.client;
    }

    function getAuth() {
        return window.ONHADA_BACKEND && window.ONHADA_BACKEND.auth;
    }

    function getDb() {
        return window.ONHADA_BACKEND && window.ONHADA_BACKEND.db;
    }

    function safeError(code, message) {
        return { code: code, message: message };
    }

    function isUuidLike(value) {
        return typeof value === 'string' && UUID_RE.test(value);
    }

    function isValidAssetFileName(value) {
        return typeof value === 'string' && ASSET_FILE_NAME_RE.test(value);
    }

    // downloadArtworkAsset 전용 경로 검증. remove와 달리 URL/역슬래시/공백/
    // query/fragment/상위경로 이동까지 명시적으로 차단한다(admin/anon도
    // 호출할 수 있어 경로 형식 자체를 더 엄격히 검사한다).
    function isValidAssetPath(path) {
        if (typeof path !== 'string' || path.length === 0) return false;
        if (path.indexOf('://') !== -1) return false;
        if (path.charAt(0) === '/') return false;
        if (path.indexOf('\\') !== -1) return false;
        if (path.indexOf(' ') !== -1) return false;
        if (path.indexOf('?') !== -1) return false;
        if (path.indexOf('#') !== -1) return false;
        if (path.indexOf('..') !== -1) return false;

        var segments = path.split('/');
        if (segments.length !== 2) return false;

        return isUuidLike(segments[0]) && isValidAssetFileName(segments[1]);
    }

    function extensionForMime(mimeType) {
        return Object.prototype.hasOwnProperty.call(ALLOWED_MIME_EXT, mimeType) ? ALLOWED_MIME_EXT[mimeType] : null;
    }

    function buildAssetPath(exhibitionId, mimeType) {
        var ext = extensionForMime(mimeType);
        if (!ext) return null;
        return exhibitionId + '/' + crypto.randomUUID() + '.' + ext;
    }

    function computeTargetDimensions(width, height) {
        if (!(width > 0) || !(height > 0)) return null;

        if (width <= MAX_DIMENSION && height <= MAX_DIMENSION) {
            return { width: width, height: height };
        }

        var scale = Math.min(MAX_DIMENSION / width, MAX_DIMENSION / height);
        return {
            width: Math.max(1, Math.round(width * scale)),
            height: Math.max(1, Math.round(height * scale))
        };
    }

    // createImageBitmap을 우선 사용하고, 지원하지 않거나 실패하는 환경에서만
    // Image + object URL 방식으로 폴백한다. 두 경로 모두 나중에 반드시
    // cleanup()을 호출해 ImageBitmap.close() / URL.revokeObjectURL()을 수행해야 한다.
    async function decodeImageSource(file) {
        if (typeof createImageBitmap === 'function') {
            try {
                var bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' });
                return {
                    source: bitmap,
                    width: bitmap.width,
                    height: bitmap.height,
                    cleanup: function () {
                        if (bitmap && typeof bitmap.close === 'function') bitmap.close();
                    }
                };
            } catch (err) {
                // 폴백으로 진행
            }
        }

        var objectUrl = URL.createObjectURL(file);
        try {
            var img = await new Promise(function (resolve, reject) {
                var el = new Image();
                el.onload = function () { resolve(el); };
                el.onerror = function () { reject(new Error('decode_failed')); };
                el.src = objectUrl;
            });

            return {
                source: img,
                width: img.naturalWidth,
                height: img.naturalHeight,
                cleanup: function () { URL.revokeObjectURL(objectUrl); }
            };
        } catch (err) {
            URL.revokeObjectURL(objectUrl);
            return null;
        }
    }

    // 이미지를 캔버스에 다시 그려 Blob으로 재인코딩한다. 캔버스는 픽셀 데이터만
    // 다루고 원본의 EXIF/GPS 등 메타데이터를 보존하지 않으므로, 이 과정 자체가
    // EXIF 제거 역할을 한다. 원본과 동일한 MIME으로만 재인코딩하며(JPEG→JPEG,
    // PNG→PNG, WEBP→WEBP), 흰색 배경을 강제로 채우지 않아 PNG 투명도를 그대로
    // 유지한다.
    //
    // 주의: 애니메이션 WebP를 입력하면 재인코딩 결과는 첫 프레임만 남은 정지
    // 이미지가 될 수 있다. 이 서비스는 정적 작품 이미지 업로드 전용이며,
    // 애니메이션 보존이 필요한 용도로는 사용하지 않는다.
    async function reencodeImage(file) {
        var decoded = await decodeImageSource(file);

        if (!decoded || !(decoded.width > 0) || !(decoded.height > 0)) {
            if (decoded && typeof decoded.cleanup === 'function') decoded.cleanup();
            return { ok: false, error: safeError('image_decode_failed', '이미지를 해석할 수 없습니다.') };
        }

        if (decoded.width * decoded.height > MAX_SOURCE_PIXELS) {
            decoded.cleanup();
            return { ok: false, error: safeError('image_processing_failed', '이미지 해상도가 너무 커서 처리할 수 없습니다.') };
        }

        var target = computeTargetDimensions(decoded.width, decoded.height);
        if (!target) {
            decoded.cleanup();
            return { ok: false, error: safeError('image_processing_failed', '이미지 크기를 계산할 수 없습니다.') };
        }

        var canvas = null;
        var blob = null;

        try {
            canvas = document.createElement('canvas');
            canvas.width = target.width;
            canvas.height = target.height;

            var ctx = canvas.getContext('2d');
            if (!ctx) {
                throw new Error('canvas_context_unavailable');
            }

            ctx.drawImage(decoded.source, 0, 0, target.width, target.height);

            var outputType = file.type;
            var quality = (outputType === 'image/jpeg' || outputType === 'image/webp') ? JPEG_WEBP_QUALITY : undefined;

            blob = await new Promise(function (resolve) {
                try {
                    canvas.toBlob(function (result) { resolve(result); }, outputType, quality);
                } catch (err) {
                    resolve(null);
                }
            });
        } catch (err) {
            decoded.cleanup();
            canvas = null;
            return { ok: false, error: safeError('image_processing_failed', '이미지 처리 중 오류가 발생했습니다.') };
        }

        decoded.cleanup();
        canvas = null; // 캔버스 참조 해제

        if (!blob) {
            return { ok: false, error: safeError('image_processing_failed', '이미지 변환에 실패했습니다.') };
        }

        return { ok: true, blob: blob, width: target.width, height: target.height, error: null };
    }

    async function uploadManagedArtworkImage(exhibitionId, file) {
        var client = getClient();
        if (!client) {
            return { ok: false, path: null, error: safeError('storage_unavailable', 'Storage 서비스를 사용할 수 없습니다.') };
        }

        if (!exhibitionId) {
            return { ok: false, path: null, error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        if (!(file instanceof File)) {
            return { ok: false, path: null, error: safeError('invalid_file', '파일 정보가 올바르지 않습니다.') };
        }

        var auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, path: null, error: safeError('storage_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        var context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, path: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, path: null, error: safeError('role_not_allowed', '이미지 업로드는 운영자 계정만 가능합니다.') };
        }

        var db = getDb();
        if (!db || typeof db.getMyManagedExhibitions !== 'function') {
            return { ok: false, path: null, error: safeError('storage_unavailable', '전시관 조회 서비스를 사용할 수 없습니다.') };
        }

        var managedResult = await db.getMyManagedExhibitions();
        if (!managedResult.ok) {
            return { ok: false, path: null, error: managedResult.error };
        }

        var isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionId; });
        if (!isManaged) {
            return { ok: false, path: null, error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        if (!Object.prototype.hasOwnProperty.call(ALLOWED_MIME_EXT, file.type)) {
            return { ok: false, path: null, error: safeError('unsupported_image_type', 'JPEG, PNG, WEBP 형식만 업로드할 수 있습니다.') };
        }

        if (!(file.size > 0) || file.size > MAX_FILE_SIZE) {
            return { ok: false, path: null, error: safeError('image_too_large', '이미지 용량은 5MB를 초과할 수 없습니다.') };
        }

        if (typeof crypto === 'undefined' || typeof crypto.randomUUID !== 'function') {
            return { ok: false, path: null, error: safeError('storage_unavailable', '이 브라우저에서는 이미지 업로드를 사용할 수 없습니다.') };
        }

        var reencoded = await reencodeImage(file);
        if (!reencoded.ok) {
            return { ok: false, path: null, error: reencoded.error };
        }

        var processedBlob = reencoded.blob;

        if (!Object.prototype.hasOwnProperty.call(ALLOWED_MIME_EXT, processedBlob.type)) {
            return { ok: false, path: null, error: safeError('image_processing_failed', '이미지 처리 결과가 올바르지 않습니다.') };
        }

        if (!(processedBlob.size > 0) || processedBlob.size > MAX_FILE_SIZE) {
            return { ok: false, path: null, error: safeError('image_too_large_after_processing', '처리된 이미지 용량이 5MB를 초과합니다.') };
        }

        // 원본 file.name은 절대 경로 생성에 사용하지 않는다. 경로는 오직
        // exhibitionId(폴더)와 crypto.randomUUID() + 확장자로만 구성한다.
        var path = buildAssetPath(exhibitionId, processedBlob.type);
        if (!path) {
            return { ok: false, path: null, error: safeError('invalid_storage_path', '저장 경로를 생성할 수 없습니다.') };
        }

        try {
            var uploadResult = await client.storage
                .from('artwork-assets')
                .upload(path, processedBlob, {
                    upsert: false,
                    contentType: processedBlob.type,
                    cacheControl: '3600'
                });

            if (uploadResult.error) {
                return { ok: false, path: null, error: safeError('upload_failed', '이미지 업로드에 실패했습니다.') };
            }

            return {
                ok: true,
                path: path,
                mimeType: processedBlob.type,
                size: processedBlob.size,
                width: reencoded.width,
                height: reencoded.height,
                error: null
            };
        } catch (err) {
            return { ok: false, path: null, error: safeError('upload_failed', '이미지 업로드 중 오류가 발생했습니다.') };
        }
    }

    async function removeManagedArtworkAsset(path) {
        var client = getClient();
        if (!client) {
            return { ok: false, error: safeError('storage_unavailable', 'Storage 서비스를 사용할 수 없습니다.') };
        }

        if (!path) {
            return { ok: false, error: safeError('invalid_storage_path', '삭제할 파일 경로가 올바르지 않습니다.') };
        }

        var auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, error: safeError('storage_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        var context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, error: safeError('role_not_allowed', '파일 삭제는 운영자 계정만 가능합니다.') };
        }

        var segments = path.split('/');
        if (segments.length !== 2 || !isUuidLike(segments[0]) || !isValidAssetFileName(segments[1])) {
            return { ok: false, error: safeError('invalid_storage_path', '삭제할 파일 경로가 올바르지 않습니다.') };
        }

        var exhibitionSegment = segments[0];

        var db = getDb();
        if (!db || typeof db.getMyManagedExhibitions !== 'function') {
            return { ok: false, error: safeError('storage_unavailable', '전시관 조회 서비스를 사용할 수 없습니다.') };
        }

        var managedResult = await db.getMyManagedExhibitions();
        if (!managedResult.ok) {
            return { ok: false, error: managedResult.error };
        }

        var isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionSegment; });
        if (!isManaged) {
            return { ok: false, error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        // approved/hidden 상태 작품이 참조하는 파일의 삭제 차단은 Storage RLS
        // (storage_artwork_assets_delete_manager)가 최종 방어선이다. 이 함수는
        // 소유(담당 전시관) 여부만 사전 확인하고, 실제 삭제 가부는 서버 정책에
        // 맡긴다.
        try {
            var removeResult = await client.storage.from('artwork-assets').remove([path]);

            if (removeResult.error) {
                return { ok: false, error: safeError('remove_failed', '파일 삭제에 실패했습니다.') };
            }

            return { ok: true, error: null };
        } catch (err) {
            return { ok: false, error: safeError('remove_failed', '파일 삭제 중 오류가 발생했습니다.') };
        }
    }

    // 업로드/삭제와 달리 role 사전 확인을 하지 않는다. admin/manager/anon
    // 모두 이 함수를 호출할 수 있으며, 실제로 그 경로를 읽을 권한이 있는지는
    // storage.objects RLS(storage_artwork_assets_select_*)가 최종 판단한다.
    // public URL이나 signed URL은 생성하지 않고, 항상 download()로 받은
    // Blob만 반환한다.
    async function downloadArtworkAsset(path) {
        var client = getClient();
        if (!client) {
            return { ok: false, blob: null, error: safeError('storage_unavailable', 'Storage 서비스를 사용할 수 없습니다.') };
        }

        if (!isValidAssetPath(path)) {
            return { ok: false, blob: null, error: safeError('invalid_storage_path', '이미지 경로 정보가 올바르지 않습니다.') };
        }

        try {
            var downloadResult = await client.storage.from('artwork-assets').download(path);

            if (downloadResult.error || !downloadResult.data) {
                return { ok: false, blob: null, error: safeError('download_failed', '이미지를 불러오지 못했습니다.') };
            }

            var blob = downloadResult.data;

            if (!Object.prototype.hasOwnProperty.call(ALLOWED_MIME_EXT, blob.type)) {
                return { ok: false, blob: null, error: safeError('invalid_downloaded_image', '이미지 형식이 올바르지 않습니다.') };
            }

            if (!(blob.size > 0) || blob.size > MAX_FILE_SIZE) {
                return { ok: false, blob: null, error: safeError('invalid_downloaded_image', '이미지 용량이 올바르지 않습니다.') };
            }

            return { ok: true, blob: blob, mimeType: blob.type, size: blob.size, error: null };
        } catch (err) {
            return { ok: false, blob: null, error: safeError('download_failed', '이미지 다운로드 중 오류가 발생했습니다.') };
        }
    }

    // =====================================================================
    // PDF 문서(artwork-documents 버킷) 전용 - 위 이미지(artwork-assets) 관련
    // 상수/검증 함수와는 완전히 분리해서 둔다. 기존 ALLOWED_MIME_EXT/
    // isValidAssetPath 등 이미지용 검증기를 느슨하게 확장하지 않는다.
    // =====================================================================

    var DOCUMENT_MAX_FILE_SIZE = 20 * 1024 * 1024; // 20971520, artwork-documents 버킷 설정과 동일
    var DOCUMENT_MIME_TYPE = 'application/pdf';
    var DOCUMENT_FILE_NAME_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$/i;

    function isValidDocumentFileName(value) {
        return typeof value === 'string' && DOCUMENT_FILE_NAME_RE.test(value);
    }

    // removeManagedArtworkDocument()/downloadArtworkDocument() 공용 - 엄격한
    // PDF 전용 경로 검증. URL/선행 슬래시/역슬래시/공백/query/fragment/상위
    // 경로 이동/2개를 초과하는 경로 구간을 모두 거부한다(downloadArtworkAsset의
    // isValidAssetPath와 동일한 엄격도).
    function isValidDocumentPath(path) {
        if (typeof path !== 'string' || path.length === 0) return false;
        if (path.indexOf('://') !== -1) return false;
        if (path.charAt(0) === '/') return false;
        if (path.indexOf('\\') !== -1) return false;
        if (path.indexOf(' ') !== -1) return false;
        if (path.indexOf('?') !== -1) return false;
        if (path.indexOf('#') !== -1) return false;
        if (path.indexOf('..') !== -1) return false;

        var segments = path.split('/');
        if (segments.length !== 2) return false;

        return isUuidLike(segments[0]) && isValidDocumentFileName(segments[1]);
    }

    function buildDocumentPath(exhibitionId) {
        return exhibitionId + '/' + crypto.randomUUID() + '.pdf';
    }

    async function uploadManagedArtworkDocument(exhibitionId, file) {
        var client = getClient();
        if (!client) {
            return { ok: false, path: null, error: safeError('storage_unavailable', 'Storage 서비스를 사용할 수 없습니다.') };
        }

        if (!isUuidLike(exhibitionId)) {
            return { ok: false, path: null, error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        if (!(file instanceof File) && !(file instanceof Blob)) {
            return { ok: false, path: null, error: safeError('invalid_file', '파일 정보가 올바르지 않습니다.') };
        }

        if (file.type !== DOCUMENT_MIME_TYPE) {
            return { ok: false, path: null, error: safeError('unsupported_document_type', 'PDF 파일만 업로드할 수 있습니다.') };
        }

        if (!(file.size > 0)) {
            return { ok: false, path: null, error: safeError('empty_file', '파일 내용이 비어 있습니다.') };
        }

        if (file.size > DOCUMENT_MAX_FILE_SIZE) {
            return { ok: false, path: null, error: safeError('document_too_large', '문서 용량은 20MB를 초과할 수 없습니다.') };
        }

        var auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, path: null, error: safeError('storage_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        var context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, path: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, path: null, error: safeError('role_not_allowed', '문서 업로드는 운영자 계정만 가능합니다.') };
        }

        var db = getDb();
        if (!db || typeof db.getMyManagedExhibitions !== 'function') {
            return { ok: false, path: null, error: safeError('storage_unavailable', '전시관 조회 서비스를 사용할 수 없습니다.') };
        }

        var managedResult = await db.getMyManagedExhibitions();
        if (!managedResult.ok) {
            return { ok: false, path: null, error: managedResult.error };
        }

        var isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionId; });
        if (!isManaged) {
            return { ok: false, path: null, error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        if (typeof crypto === 'undefined' || typeof crypto.randomUUID !== 'function') {
            return { ok: false, path: null, error: safeError('storage_unavailable', '이 브라우저에서는 문서 업로드를 사용할 수 없습니다.') };
        }

        // 원본 file.name은 절대 경로 생성에 사용하지 않는다. 경로는 오직
        // exhibitionId(폴더)와 crypto.randomUUID() + .pdf로만 구성한다.
        // PDF는 이미지와 달리 Canvas 재인코딩/EXIF 제거를 하지 않고 원본
        // Blob(File)을 그대로 업로드한다.
        var path = buildDocumentPath(exhibitionId);

        try {
            var uploadResult = await client.storage
                .from('artwork-documents')
                .upload(path, file, {
                    upsert: false,
                    contentType: DOCUMENT_MIME_TYPE
                });

            if (uploadResult.error) {
                return { ok: false, path: null, error: safeError('upload_failed', '문서 업로드에 실패했습니다.') };
            }

            return { ok: true, path: path, error: null };
        } catch (err) {
            return { ok: false, path: null, error: safeError('upload_failed', '문서 업로드 중 오류가 발생했습니다.') };
        }
    }

    // 보상 삭제 전용. approved/hidden 상태 작품이 참조하는 파일의 삭제 차단은
    // Storage RLS(storage_artwork_documents_delete_manager)가 최종 방어선이다.
    // 이 함수는 소유(담당 전시관) 여부만 사전 확인하고, 실제 삭제 가부는
    // 서버 정책에 맡긴다.
    async function removeManagedArtworkDocument(path) {
        var client = getClient();
        if (!client) {
            return { ok: false, error: safeError('storage_unavailable', 'Storage 서비스를 사용할 수 없습니다.') };
        }

        if (!isValidDocumentPath(path)) {
            return { ok: false, error: safeError('invalid_storage_path', '삭제할 파일 경로가 올바르지 않습니다.') };
        }

        var auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, error: safeError('storage_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        var context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, error: safeError('role_not_allowed', '파일 삭제는 운영자 계정만 가능합니다.') };
        }

        var segments = path.split('/');
        var exhibitionSegment = segments[0];

        var db = getDb();
        if (!db || typeof db.getMyManagedExhibitions !== 'function') {
            return { ok: false, error: safeError('storage_unavailable', '전시관 조회 서비스를 사용할 수 없습니다.') };
        }

        var managedResult = await db.getMyManagedExhibitions();
        if (!managedResult.ok) {
            return { ok: false, error: managedResult.error };
        }

        var isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionSegment; });
        if (!isManaged) {
            return { ok: false, error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        try {
            var removeResult = await client.storage.from('artwork-documents').remove([path]);

            if (removeResult.error) {
                return { ok: false, error: safeError('remove_failed', '파일 삭제에 실패했습니다.') };
            }

            return { ok: true, error: null };
        } catch (err) {
            return { ok: false, error: safeError('remove_failed', '파일 삭제 중 오류가 발생했습니다.') };
        }
    }

    // 업로드/삭제와 달리 role 사전 확인을 하지 않는다. admin/manager/anon
    // 모두 이 함수를 호출할 수 있으며, 실제로 그 경로를 읽을 권한이 있는지는
    // storage.objects RLS(storage_artwork_documents_select_*)가 최종 판단한다.
    // public URL이나 signed URL은 생성하지 않고, 항상 download()로 받은
    // Blob만 반환한다. object URL 생성/정리는 이 서비스가 하지 않고 호출한
    // UI가 필요할 때 만들고 정리한다.
    async function downloadArtworkDocument(path) {
        var client = getClient();
        if (!client) {
            return { ok: false, blob: null, error: safeError('storage_unavailable', 'Storage 서비스를 사용할 수 없습니다.') };
        }

        if (!isValidDocumentPath(path)) {
            return { ok: false, blob: null, error: safeError('invalid_storage_path', '문서 경로 정보가 올바르지 않습니다.') };
        }

        try {
            var downloadResult = await client.storage.from('artwork-documents').download(path);

            if (downloadResult.error || !downloadResult.data) {
                return { ok: false, blob: null, error: safeError('download_failed', '문서를 불러오지 못했습니다.') };
            }

            var blob = downloadResult.data;

            if (blob.type !== DOCUMENT_MIME_TYPE) {
                return { ok: false, blob: null, error: safeError('invalid_downloaded_document', '문서 형식이 올바르지 않습니다.') };
            }

            if (!(blob.size > 0) || blob.size > DOCUMENT_MAX_FILE_SIZE) {
                return { ok: false, blob: null, error: safeError('invalid_downloaded_document', '문서 용량이 올바르지 않습니다.') };
            }

            return { ok: true, blob: blob, mimeType: blob.type, size: blob.size, error: null };
        } catch (err) {
            return { ok: false, blob: null, error: safeError('download_failed', '문서 다운로드 중 오류가 발생했습니다.') };
        }
    }

    // =====================================================================
    // MP4 영상(artwork-video-assets 버킷) 전용 - 위 이미지/PDF 관련 상수/검증
    // 함수와는 완전히 분리해서 둔다. 관리자 위저드는 브라우저가 로컬로
    // 선택한 File을 그대로 미리보기하므로 업로드 전 다운로드가 필요 없지만,
    // 공개 상세보기 모달은 이미 업로드된 직접 업로드 영상을 재생하기 위해
    // downloadArtworkVideo()로 Blob을 받아야 한다.
    // =====================================================================

    var VIDEO_MAX_FILE_SIZE = 50 * 1024 * 1024; // 52428800, artwork-video-assets 버킷 설정과 동일
    var VIDEO_MIME_TYPE = 'video/mp4';
    var VIDEO_FILE_NAME_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.mp4$/i;

    function isValidVideoFileName(value) {
        return typeof value === 'string' && VIDEO_FILE_NAME_RE.test(value);
    }

    // removeManagedArtworkVideo() 전용 - isValidDocumentPath()와 동일한
    // 엄격도의 경로 검증(URL/선행 슬래시/역슬래시/공백/query/fragment/상위
    // 경로 이동/2개를 초과하는 경로 구간을 모두 거부).
    function isValidVideoPath(path) {
        if (typeof path !== 'string' || path.length === 0) return false;
        if (path.indexOf('://') !== -1) return false;
        if (path.charAt(0) === '/') return false;
        if (path.indexOf('\\') !== -1) return false;
        if (path.indexOf(' ') !== -1) return false;
        if (path.indexOf('?') !== -1) return false;
        if (path.indexOf('#') !== -1) return false;
        if (path.indexOf('..') !== -1) return false;

        var segments = path.split('/');
        if (segments.length !== 2) return false;

        return isUuidLike(segments[0]) && isValidVideoFileName(segments[1]);
    }

    function buildVideoPath(exhibitionId) {
        return exhibitionId + '/' + crypto.randomUUID() + '.mp4';
    }

    async function uploadManagedArtworkVideo(exhibitionId, file) {
        var client = getClient();
        if (!client) {
            return { ok: false, path: null, error: safeError('storage_unavailable', 'Storage 서비스를 사용할 수 없습니다.') };
        }

        if (!isUuidLike(exhibitionId)) {
            return { ok: false, path: null, error: safeError('invalid_exhibition_id', '전시관 정보가 올바르지 않습니다.') };
        }

        if (!(file instanceof File) && !(file instanceof Blob)) {
            return { ok: false, path: null, error: safeError('invalid_file', '파일 정보가 올바르지 않습니다.') };
        }

        if (file.type !== VIDEO_MIME_TYPE) {
            return { ok: false, path: null, error: safeError('unsupported_video_type', 'MP4 파일만 업로드할 수 있습니다.') };
        }

        if (!(file.size > 0)) {
            return { ok: false, path: null, error: safeError('empty_file', '파일 내용이 비어 있습니다.') };
        }

        if (file.size > VIDEO_MAX_FILE_SIZE) {
            return { ok: false, path: null, error: safeError('video_too_large', '영상 용량은 50MB를 초과할 수 없습니다.') };
        }

        var auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, path: null, error: safeError('storage_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        var context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, path: null, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, path: null, error: safeError('role_not_allowed', '영상 업로드는 운영자 계정만 가능합니다.') };
        }

        var db = getDb();
        if (!db || typeof db.getMyManagedExhibitions !== 'function') {
            return { ok: false, path: null, error: safeError('storage_unavailable', '전시관 조회 서비스를 사용할 수 없습니다.') };
        }

        var managedResult = await db.getMyManagedExhibitions();
        if (!managedResult.ok) {
            return { ok: false, path: null, error: managedResult.error };
        }

        var isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionId; });
        if (!isManaged) {
            return { ok: false, path: null, error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        if (typeof crypto === 'undefined' || typeof crypto.randomUUID !== 'function') {
            return { ok: false, path: null, error: safeError('storage_unavailable', '이 브라우저에서는 영상 업로드를 사용할 수 없습니다.') };
        }

        // 원본 file.name은 절대 경로 생성에 사용하지 않는다. 경로는 오직
        // exhibitionId(폴더)와 crypto.randomUUID() + .mp4로만 구성한다.
        // 영상은 이미지와 달리 Canvas 재인코딩을 하지 않고 원본 Blob(File)을
        // 그대로 업로드한다(재인코딩은 썸네일 캡처 단계에서만 발생).
        var path = buildVideoPath(exhibitionId);

        try {
            var uploadResult = await client.storage
                .from('artwork-video-assets')
                .upload(path, file, {
                    upsert: false,
                    contentType: VIDEO_MIME_TYPE
                });

            if (uploadResult.error) {
                return { ok: false, path: null, error: safeError('upload_failed', '영상 업로드에 실패했습니다.') };
            }

            return { ok: true, path: path, error: null };
        } catch (err) {
            return { ok: false, path: null, error: safeError('upload_failed', '영상 업로드 중 오류가 발생했습니다.') };
        }
    }

    // 보상 삭제 전용. approved/hidden 상태 작품이 참조하는 파일의 삭제 차단은
    // Storage RLS(storage_artwork_video_assets_delete_manager)가 최종 방어선이다.
    // 이 함수는 소유(담당 전시관) 여부만 사전 확인하고, 실제 삭제 가부는
    // 서버 정책에 맡긴다.
    async function removeManagedArtworkVideo(path) {
        var client = getClient();
        if (!client) {
            return { ok: false, error: safeError('storage_unavailable', 'Storage 서비스를 사용할 수 없습니다.') };
        }

        if (!isValidVideoPath(path)) {
            return { ok: false, error: safeError('invalid_storage_path', '삭제할 파일 경로가 올바르지 않습니다.') };
        }

        var auth = getAuth();
        if (!auth || typeof auth.getCurrentUserContext !== 'function') {
            return { ok: false, error: safeError('storage_unavailable', '인증 서비스를 사용할 수 없습니다.') };
        }

        var context = await auth.getCurrentUserContext();

        if (!context || !context.signedIn || !context.userId) {
            return { ok: false, error: safeError('not_signed_in', '로그인이 필요합니다.') };
        }

        if (!context.profile || context.profile.role !== 'manager') {
            return { ok: false, error: safeError('role_not_allowed', '파일 삭제는 운영자 계정만 가능합니다.') };
        }

        var segments = path.split('/');
        var exhibitionSegment = segments[0];

        var db = getDb();
        if (!db || typeof db.getMyManagedExhibitions !== 'function') {
            return { ok: false, error: safeError('storage_unavailable', '전시관 조회 서비스를 사용할 수 없습니다.') };
        }

        var managedResult = await db.getMyManagedExhibitions();
        if (!managedResult.ok) {
            return { ok: false, error: managedResult.error };
        }

        var isManaged = managedResult.exhibitions.some(function (ex) { return ex.id === exhibitionSegment; });
        if (!isManaged) {
            return { ok: false, error: safeError('not_managed', '담당하지 않는 전시관입니다.') };
        }

        try {
            var removeResult = await client.storage.from('artwork-video-assets').remove([path]);

            if (removeResult.error) {
                return { ok: false, error: safeError('remove_failed', '파일 삭제에 실패했습니다.') };
            }

            return { ok: true, error: null };
        } catch (err) {
            return { ok: false, error: safeError('remove_failed', '파일 삭제 중 오류가 발생했습니다.') };
        }
    }

    // 공개 관람객용 직접 업로드 영상 다운로드. downloadArtworkAsset/
    // downloadArtworkDocument와 동일하게 role 사전 확인을 하지 않는다.
    // admin/manager/anon 모두 호출할 수 있으며, 실제로 그 경로를 읽을 권한이
    // 있는지는 storage.objects RLS(storage_artwork_video_assets_select_*)가
    // 최종 판단한다. removeManagedArtworkVideo()와 동일한 isValidVideoPath()를
    // 그대로 재사용해 경로를 검증한다. public URL이나 signed URL은 생성하지
    // 않고, 항상 download()로 받은 Blob만 반환한다. object URL 생성/정리는
    // 이 서비스가 하지 않고 호출한 UI가 필요할 때 만들고 정리한다.
    async function downloadArtworkVideo(path) {
        var client = getClient();
        if (!client) {
            return { ok: false, blob: null, error: safeError('storage_unavailable', 'Storage 서비스를 사용할 수 없습니다.') };
        }

        if (!isValidVideoPath(path)) {
            return { ok: false, blob: null, error: safeError('invalid_storage_path', '영상 경로 정보가 올바르지 않습니다.') };
        }

        try {
            var downloadResult = await client.storage.from('artwork-video-assets').download(path);

            if (downloadResult.error || !downloadResult.data) {
                return { ok: false, blob: null, error: safeError('download_failed', '영상을 불러오지 못했습니다.') };
            }

            var blob = downloadResult.data;

            if (blob.type !== VIDEO_MIME_TYPE) {
                return { ok: false, blob: null, error: safeError('invalid_downloaded_video', '영상 형식이 올바르지 않습니다.') };
            }

            if (!(blob.size > 0) || blob.size > VIDEO_MAX_FILE_SIZE) {
                return { ok: false, blob: null, error: safeError('invalid_downloaded_video', '영상 용량이 올바르지 않습니다.') };
            }

            return { ok: true, blob: blob, mimeType: blob.type, size: blob.size, error: null };
        } catch (err) {
            return { ok: false, blob: null, error: safeError('download_failed', '영상 다운로드 중 오류가 발생했습니다.') };
        }
    }

    window.ONHADA_BACKEND.storage = {
        uploadManagedArtworkImage: uploadManagedArtworkImage,
        removeManagedArtworkAsset: removeManagedArtworkAsset,
        downloadArtworkAsset: downloadArtworkAsset,
        uploadManagedArtworkDocument: uploadManagedArtworkDocument,
        removeManagedArtworkDocument: removeManagedArtworkDocument,
        downloadArtworkDocument: downloadArtworkDocument,
        uploadManagedArtworkVideo: uploadManagedArtworkVideo,
        removeManagedArtworkVideo: removeManagedArtworkVideo,
        downloadArtworkVideo: downloadArtworkVideo
    };
})();
