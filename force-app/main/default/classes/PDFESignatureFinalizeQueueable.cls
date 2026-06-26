public without sharing class PDFESignatureFinalizeQueueable implements Queueable, Database.AllowsCallouts {
    private Id envelopeId;

    public PDFESignatureFinalizeQueueable(Id envelopeId) {
        this.envelopeId = envelopeId;
    }

    public void execute(QueueableContext context) {
        String finalizerDebugContext = null;
        PDF_ESignature_Envelope__c env = [
            SELECT Id, Name, Envelope_Status__c, Parent_Record_Id__c, Parent_Object_Api_Name__c,
                   Signer_Name__c, Signer_Email__c, Signer_Title__c, Signed_At__c,
                   Signature_Image_Data_Url__c, Final_ContentDocument_Id__c, Final_ContentVersion_Id__c
            FROM PDF_ESignature_Envelope__c
            WHERE Id = :envelopeId
            LIMIT 1
        ];
        try {
            PDF_ESignature_Setting__mdt settings = PDFESignatureUtil.getSettings();
            String namedCredential = String.isBlank(settings.Finalizer_Named_Credential__c)
                ? 'PDFESign_PowerAutomateFinalizer'
                : settings.Finalizer_Named_Credential__c.trim();
            ContentVersion source = PDFESignatureUtil.getLatestSourceVersion(env, true);
            if (source == null) {
                throw new PDFESignatureUtil.AppException('Source PDF not found for envelope ' + env.Id + '.');
            }
            Map<String, Object> payload = buildPayload(env, source, settings);
            finalizerDebugContext = PDFESignatureUtil.stringValue(payload.get('finalizerDebugText'));
            System.debug(LoggingLevel.INFO, 'PDF E-Signature finalizer request for envelope ' + env.Id + ': ' + finalizerDebugContext);

            HttpRequest request = new HttpRequest();
            request.setMethod('POST');
            request.setEndpoint('callout:' + namedCredential);
            request.setHeader('Content-Type', 'application/json');
            request.setTimeout(120000);
            request.setBody(JSON.serialize(payload));

            HttpResponse response = new Http().send(request);
            Integer statusCode = response.getStatusCode();
            if (statusCode < 200 || statusCode >= 300) {
                throw new PDFESignatureUtil.AppException('Power Automate finalizer returned HTTP ' + statusCode + ': ' + response.getBody());
            }

            Map<String, Object> body = parseResponseBody(response.getBody());
            Boolean success = PDFESignatureUtil.boolValue(body.get('success'), true);
            if (!success) {
                throw new PDFESignatureUtil.AppException(PDFESignatureUtil.firstNonBlank(new List<String>{
                    PDFESignatureUtil.stringValue(body.get('message')),
                    'Power Automate finalizer reported success=false.'
                }));
            }

            String finalPdfBase64 = normalizeReturnedPdfBase64(PDFESignatureUtil.stringValue(body.get('finalPdfBase64')));
            if (String.isBlank(finalPdfBase64)) {
                throw new PDFESignatureUtil.AppException(
                    'Power Automate synchronous finalizer response did not include finalPdfBase64. '
                    + 'The PDF-first finalizer requires finalPdfBase64 in the initial HTTP response. '
                    + responseKeySummary(body)
                );
            }

            String completionMessage = PDFESignatureUtil.firstNonBlank(new List<String>{
                PDFESignatureUtil.stringValue(body.get('message')),
                'Final signed PDF was created.'
            });
            completionMessage = appendDebugSummary(completionMessage, finalizerDebugContext);
            PDFESignatureFinalizerService.completeWithBase64(
                env.Id,
                finalPdfBase64,
                PDFESignatureUtil.stringValue(body.get('fileName')),
                completionMessage
            );
        } catch (Exception e) {
            String errorMessage = e.getMessage() + '\n' + e.getStackTraceString();
            if (!String.isBlank(finalizerDebugContext)) {
                errorMessage += '\nFinalizer debug: ' + finalizerDebugContext;
            }
            PDFESignatureFinalizerService.markError(env.Id, errorMessage);
        }
    }

    private Map<String, Object> buildPayload(PDF_ESignature_Envelope__c env, ContentVersion source, PDF_ESignature_Setting__mdt settings) {
        Map<String, Object> payload = new Map<String, Object>();
        payload.put('envelopeId', env.Id);
        payload.put('status', env.Envelope_Status__c);
        payload.put('parentRecordId', env.Parent_Record_Id__c);
        payload.put('parentObjectApiName', env.Parent_Object_Api_Name__c);
        payload.put('sourceContentDocumentId', source.ContentDocumentId);
        payload.put('sourceContentVersionId', source.Id);
        payload.put('sourceFileName', source.Title + '.pdf');
        if (settings.Include_Source_PDF_In_Finalizer_Request__c == null || settings.Include_Source_PDF_In_Finalizer_Request__c) {
            payload.put('sourcePdfBase64', EncodingUtil.base64Encode(source.VersionData));
        }
        payload.put('finalFileName', source.Title + ' - signed.pdf');
        payload.put('signerName', env.Signer_Name__c);
        payload.put('signerEmail', env.Signer_Email__c);
        payload.put('signerTitle', env.Signer_Title__c);
        payload.put('signedAt', env.Signed_At__c == null ? System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : env.Signed_At__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        payload.put('signatureImageDataUrl', env.Signature_Image_Data_Url__c);
        payload.put('pageWidth', 612);
        payload.put('pageHeight', 792);

        List<Map<String, Object>> stampOverlays = PDFESignatureOverlayBuilder.buildOverlayPayloads(env.Id);
        Map<String, Object> overlayDebug = PDFESignatureOverlayBuilder.buildOverlayDebugInfo(stampOverlays);
        String overlayDebugText = 'stampOverlays=' + String.valueOf(overlayDebug.get('stampOverlayCount'))
            + '; pages=' + PDFESignatureUtil.stringValue(overlayDebug.get('stampOverlayPagesText'))
            + '; sourceContentVersionId=' + String.valueOf(source.Id)
            + '; sourceContentDocumentId=' + String.valueOf(source.ContentDocumentId);
        payload.put('stampOverlays', stampOverlays);
        payload.put('stampOverlayMode', 'AdobeWatermarkPageByPage');
        payload.put('stampOverlayCount', overlayDebug.get('stampOverlayCount'));
        payload.put('stampOverlayPages', overlayDebug.get('stampOverlayPages'));
        payload.put('finalizerDebug', overlayDebug);
        payload.put('finalizerDebugText', overlayDebugText);

        Map<String, Object> callback = new Map<String, Object>();
        callback.put('url', PDFESignatureUtil.buildFinalizerCallbackUrl(settings));
        callback.put('secret', settings.Finalizer_Callback_Secret__c);
        callback.put('headerName', 'X-PDF-ESignature-Secret');
        callback.put('mode', String.isBlank(settings.Finalizer_Mode__c) ? 'PowerAutomateSync' : settings.Finalizer_Mode__c);
        payload.put('callback', callback);

        List<Object> fieldPayload = new List<Object>();
        for (PDF_ESignature_Field__c field : [
            SELECT Id, Field_Type__c, Label__c, Page_Number__c, X_Percent__c, Y_Percent__c,
                   Width_Percent__c, Height_Percent__c, Pdf_X__c, Pdf_Y__c, Pdf_Width__c,
                   Pdf_Height__c, Page_Width_Points__c, Page_Height_Points__c, Value__c,
                   Completed__c, Required__c, Sequence__c
            FROM PDF_ESignature_Field__c
            WHERE Envelope__c = :env.Id
            ORDER BY Page_Number__c ASC, Sequence__c ASC, CreatedDate ASC
        ]) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('id', field.Id);
            row.put('type', field.Field_Type__c);
            row.put('label', field.Label__c);
            row.put('pageNumber', field.Page_Number__c == null ? 1 : Integer.valueOf(field.Page_Number__c));
            row.put('xPercent', field.X_Percent__c);
            row.put('yPercent', field.Y_Percent__c);
            row.put('widthPercent', field.Width_Percent__c);
            row.put('heightPercent', field.Height_Percent__c);
            row.put('pdfX', field.Pdf_X__c);
            row.put('pdfY', field.Pdf_Y__c);
            row.put('pdfWidth', field.Pdf_Width__c);
            row.put('pdfHeight', field.Pdf_Height__c);
            row.put('pageWidth', field.Page_Width_Points__c == null ? 612 : field.Page_Width_Points__c);
            row.put('pageHeight', field.Page_Height_Points__c == null ? 792 : field.Page_Height_Points__c);
            row.put('value', field.Value__c);
            row.put('completed', field.Completed__c);
            row.put('required', field.Required__c);
            fieldPayload.add(row);
        }
        payload.put('fields', fieldPayload);

        Map<String, Object> lockOptions = new Map<String, Object>();
        lockOptions.put('restrictEditing', settings.Restrict_Editing__c);
        lockOptions.put('restrictCopying', settings.Restrict_Copying__c);
        lockOptions.put('allowLowQualityPrinting', settings.Allow_Low_Quality_Printing__c);
        lockOptions.put('ownerPassword', settings.Final_Pdf_Owner_Password__c);
        payload.put('lock', lockOptions);
        return payload;
    }

    private Map<String, Object> parseResponseBody(String rawBody) {
        if (String.isBlank(rawBody)) {
            return new Map<String, Object>();
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(rawBody);
        } catch (Exception e) {
            return new Map<String, Object>{ 'message' => rawBody };
        }
    }

    private static String normalizeReturnedPdfBase64(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String output = value.trim();
        Integer commaIndex = output.indexOf(',');
        if (output.toLowerCase().startsWith('data:application/pdf') && commaIndex >= 0) {
            output = output.substring(commaIndex + 1).trim();
        }
        return output;
    }

    private static String responseKeySummary(Map<String, Object> body) {
        if (body == null || body.isEmpty()) {
            return 'Response body was empty or not JSON.';
        }
        List<String> keys = new List<String>(body.keySet());
        keys.sort();
        return 'Response keys: ' + String.join(keys, ', ') + '.';
    }

    private static String appendDebugSummary(String message, String debugText) {
        if (String.isBlank(debugText)) {
            return message;
        }
        String baseMessage = String.isBlank(message) ? 'Final signed PDF was created.' : message;
        return baseMessage + ' Finalizer debug: ' + debugText;
    }
}