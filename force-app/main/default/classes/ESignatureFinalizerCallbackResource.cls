@RestResource(urlMapping='/ESignature/v1/finalizer-callback')
global without sharing class ESignatureFinalizerCallbackResource {
    @HttpPost
    global static void postResult() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');
        try {
            Map<String, Object> body = parseRequestBody();
            validateSecret(body);

            Id envelopeId = ESignatureUtil.safeId(ESignatureUtil.stringValue(body.get('envelopeId')));
            if (envelopeId == null) {
                throw new ESignatureUtil.AppException('Callback payload must include envelopeId.');
            }

            Boolean success = ESignatureUtil.boolValue(body.get('success'), true);
            String message = ESignatureUtil.stringValue(body.get('message'));
            if (!success) {
                ESignatureFinalizerService.markError(envelopeId, message);
                writeJson(200, new Map<String, Object>{
                    'success' => true,
                    'message' => 'Envelope was marked Error.'
                });
                return;
            }

            String finalPdfBase64 = ESignatureUtil.stringValue(body.get('finalPdfBase64'));
            String fileName = ESignatureUtil.stringValue(body.get('fileName'));
            if (!String.isBlank(finalPdfBase64)) {
                ESignatureFinalizerService.completeWithBase64(envelopeId, finalPdfBase64, fileName, message);
            } else {
                Id finalContentVersionId = ESignatureUtil.safeId(ESignatureUtil.firstNonBlank(new List<String>{
                    ESignatureUtil.stringValue(body.get('finalContentVersionId')),
                    ESignatureUtil.stringValue(body.get('contentVersionId'))
                }));
                Id finalContentDocumentId = ESignatureUtil.safeId(ESignatureUtil.firstNonBlank(new List<String>{
                    ESignatureUtil.stringValue(body.get('finalContentDocumentId')),
                    ESignatureUtil.stringValue(body.get('contentDocumentId'))
                }));
                ESignatureFinalizerService.completeWithExistingFile(envelopeId, finalContentVersionId, finalContentDocumentId, message);
            }

            writeJson(200, new Map<String, Object>{
                'success' => true,
                'message' => 'Envelope finalized.'
            });
        } catch (Exception e) {
            String errorMessage = e.getMessage();
            Integer statusCode = 400;
            if (errorMessage != null && errorMessage.contains('Unauthorized')) {
                statusCode = 401;
            } else if (errorMessage != null && errorMessage.contains('callback secret is not configured')) {
                statusCode = 500;
            }
            writeJson(statusCode, new Map<String, Object>{
                'success' => false,
                'message' => errorMessage
            });
        }
    }

    private static Map<String, Object> parseRequestBody() {
        Blob requestBody = RestContext.request.requestBody;
        String rawBody = requestBody == null ? null : requestBody.toString();
        if (String.isBlank(rawBody)) {
            return new Map<String, Object>();
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(rawBody);
        } catch (Exception e) {
            throw new ESignatureUtil.AppException('Callback request body must be a JSON object.');
        }
    }

    private static void validateSecret(Map<String, Object> body) {
        ESignature_Setting__mdt settings = ESignatureUtil.getSettings();
        String expected = settings.Finalizer_Callback_Secret__c;
        if (String.isBlank(expected)) {
            throw new ESignatureUtil.AppException('Finalizer callback secret is not configured.');
        }
        String provided = RestContext.request.headers.get('X-PDF-ESignature-Secret');
        if (String.isBlank(provided)) {
            provided = ESignatureUtil.stringValue(body.get('callbackSecret'));
        }
        if (String.isBlank(provided)) {
            provided = ESignatureUtil.stringValue(body.get('secret'));
        }
        if (String.isBlank(provided) || !secretsMatch(provided, expected)) {
            throw new ESignatureUtil.AppException('Unauthorized finalizer callback.');
        }
    }

    private static Boolean secretsMatch(String provided, String expected) {
        if (provided == null || expected == null) {
            return false;
        }
        String providedDigest = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(provided)));
        String expectedDigest = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(expected)));
        Integer mismatchCount = 0;
        for (Integer index = 0; index < expectedDigest.length(); index++) {
            if (providedDigest.substring(index, index + 1) != expectedDigest.substring(index, index + 1)) {
                mismatchCount++;
            }
        }
        return mismatchCount == 0;
    }

    private static void writeJson(Integer statusCode, Map<String, Object> body) {
        RestContext.response.statusCode = statusCode;
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(body));
    }
}
