@RestResource(urlMapping='/PDFESign/v1/finalizer-callback')
global without sharing class PDFESignatureFinalizerCallbackResource {
    @HttpPost
    global static void postResult() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');
        try {
            Map<String, Object> body = parseRequestBody();
            validateSecret(body);

            Id envelopeId = PDFESignatureUtil.safeId(PDFESignatureUtil.stringValue(body.get('envelopeId')));
            if (envelopeId == null) {
                throw new PDFESignatureUtil.AppException('Callback payload must include envelopeId.');
            }

            Boolean success = PDFESignatureUtil.boolValue(body.get('success'), true);
            String message = PDFESignatureUtil.stringValue(body.get('message'));
            if (!success) {
                PDFESignatureFinalizerService.markError(envelopeId, message);
                writeJson(200, new Map<String, Object>{
                    'success' => true,
                    'message' => 'Envelope was marked Error.'
                });
                return;
            }

            String finalPdfBase64 = PDFESignatureUtil.stringValue(body.get('finalPdfBase64'));
            String fileName = PDFESignatureUtil.stringValue(body.get('fileName'));
            if (!String.isBlank(finalPdfBase64)) {
                PDFESignatureFinalizerService.completeWithBase64(envelopeId, finalPdfBase64, fileName, message);
            } else {
                Id finalContentVersionId = PDFESignatureUtil.safeId(PDFESignatureUtil.firstNonBlank(new List<String>{
                    PDFESignatureUtil.stringValue(body.get('finalContentVersionId')),
                    PDFESignatureUtil.stringValue(body.get('contentVersionId'))
                }));
                Id finalContentDocumentId = PDFESignatureUtil.safeId(PDFESignatureUtil.firstNonBlank(new List<String>{
                    PDFESignatureUtil.stringValue(body.get('finalContentDocumentId')),
                    PDFESignatureUtil.stringValue(body.get('contentDocumentId'))
                }));
                PDFESignatureFinalizerService.completeWithExistingFile(envelopeId, finalContentVersionId, finalContentDocumentId, message);
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
            throw new PDFESignatureUtil.AppException('Callback request body must be a JSON object.');
        }
    }

    private static void validateSecret(Map<String, Object> body) {
        ESignature_Setting__mdt settings = PDFESignatureUtil.getSettings();
        String expected = settings.Finalizer_Callback_Secret__c;
        if (String.isBlank(expected)) {
            throw new PDFESignatureUtil.AppException('Finalizer callback secret is not configured.');
        }
        String provided = RestContext.request.headers.get('X-PDF-ESignature-Secret');
        if (String.isBlank(provided)) {
            provided = PDFESignatureUtil.stringValue(body.get('callbackSecret'));
        }
        if (String.isBlank(provided)) {
            provided = PDFESignatureUtil.stringValue(body.get('secret'));
        }
        if (String.isBlank(provided) || !secretsMatch(provided, expected)) {
            throw new PDFESignatureUtil.AppException('Unauthorized finalizer callback.');
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
