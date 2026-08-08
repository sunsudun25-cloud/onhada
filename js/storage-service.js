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

    window.ONHADA_BACKEND.storage = {
        uploadManagedArtworkImage: uploadManagedArtworkImage,
        removeManagedArtworkAsset: removeManagedArtworkAsset,
        downloadArtworkAsset: downloadArtworkAsset
    };
})();
