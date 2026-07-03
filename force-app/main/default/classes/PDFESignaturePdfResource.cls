@RestResource(urlMapping='/PDFESign/v1/pdf')
global without sharing class PDFESignaturePdfResource {
    @HttpGet
    global static void getPdf() {
        RestResponse response = RestContext.response;
        String token = RestContext.request.params.get('t');
        ESignature_Envelope__c env = PDFESignatureUtil.findEnvelopeByToken(token);
        if (env == null) {
            response.statusCode = 404;
            response.responseBody = Blob.valueOf('Document not found.');
            return;
        }
        if (env.Expires_At__c != null && env.Expires_At__c < System.now()) {
            response.statusCode = 403;
            response.responseBody = Blob.valueOf('This signing link has expired.');
            return;
        }
        if (isCompletedEnvelope(env)) {
            response.statusCode = 410;
            response.addHeader('Content-Type', 'text/plain; charset=UTF-8');
            response.responseBody = Blob.valueOf('This document has already been completed.');
            return;
        }
        if (isDeclinedEnvelope(env)) {
            response.statusCode = 410;
            response.addHeader('Content-Type', 'text/plain; charset=UTF-8');
            response.responseBody = Blob.valueOf('This document has already been declined.');
            return;
        }
        if (isCancelledEnvelope(env)) {
            response.statusCode = 410;
            response.addHeader('Content-Type', 'text/plain; charset=UTF-8');
            response.responseBody = Blob.valueOf('This document has already been cancelled.');
            return;
        }
        Blob pdfData = PDFESignatureUtil.getCachedSourcePdfBlob(env.Id);
        if (pdfData == null) {
            ContentVersion source = PDFESignatureUtil.getLatestSourceVersion(env, true);
            if (source != null) {
                pdfData = source.VersionData;
            }
        }
        if (pdfData == null) {
            response.statusCode = 404;
            response.addHeader('Content-Type', 'text/plain; charset=UTF-8');
            response.responseBody = Blob.valueOf('Source PDF not found for envelope ' + String.valueOf(env.Id) + '. Verify ESignature_Source_Chunk__c rows exist for this envelope, or resend the envelope after v13 is deployed.');
            return;
        }
        response.statusCode = 200;
        response.addHeader('Content-Type', 'application/pdf');
        response.addHeader('Cache-Control', 'private, no-store, no-cache, max-age=0');
        response.addHeader('Content-Disposition', 'inline; filename="' + pdfFileName(PDFESignatureUtil.getEnvelopeTitle(env)) + '"');
        response.responseBody = pdfData;
    }

    private static Boolean isCompletedEnvelope(ESignature_Envelope__c env) {
        if (env == null) {
            return false;
        }
        if (env.Signed_At__c != null) {
            return true;
        }
        return new Set<String>{ 'signed', 'finalizing', 'completed', 'complete' }.contains(normalizedEnvelopeStatus(env));
    }

    private static Boolean isCancelledEnvelope(ESignature_Envelope__c env) {
        String status = normalizedEnvelopeStatus(env);
        return new Set<String>{ 'cancelled', 'canceled', 'voided', 'cancelled by sender', 'canceled by sender' }.contains(status) ||
            status.contains('cancel') ||
            status.contains('void');
    }

    private static Boolean isDeclinedEnvelope(ESignature_Envelope__c env) {
        if (env == null) {
            return false;
        }
        if (!String.isBlank(PDFESignatureUtil.stringValue(env.Decline_Reason__c))) {
            return true;
        }
        String status = normalizedEnvelopeStatus(env);
        return status == 'declined' ||
            status.contains('declin') ||
            status.contains('reject');
    }

    private static String normalizedEnvelopeStatus(ESignature_Envelope__c env) {
        if (env == null) {
            return '';
        }
        String status = PDFESignatureUtil.stringValue(env.Envelope_Status__c);
        if (String.isBlank(status)) {
            try {
                status = PDFESignatureUtil.stringValue(env.get('Status__c'));
            } catch (Exception ignore) {
                status = null;
            }
        }
        return String.isBlank(status) ? '' : status.trim().toLowerCase();
    }

    private static String pdfFileName(String title) {
        String fileName = sanitizeFileName(title);
        if (!fileName.toLowerCase().endsWith('.pdf')) {
            fileName += '.pdf';
        }
        return fileName;
    }

    private static String sanitizeFileName(String value) {
        String cleaned = String.isBlank(value) ? 'Document' : value.trim();
        cleaned = cleaned.replaceAll('[\\\\/:*?"<>|\\r\\n\\t]', ' ');
        cleaned = cleaned.replaceAll('\\s+', ' ').trim();
        while (cleaned.endsWith('.')) {
            cleaned = cleaned.substring(0, cleaned.length() - 1).trim();
        }
        if (String.isBlank(cleaned)) {
            cleaned = 'Document';
        }
        if (cleaned.length() > 180) {
            cleaned = cleaned.substring(0, 180).trim();
        }
        return cleaned;
    }
}
