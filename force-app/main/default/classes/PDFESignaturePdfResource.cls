@RestResource(urlMapping='/PDFESign/v1/pdf')
global without sharing class PDFESignaturePdfResource {
    @HttpGet
    global static void getPdf() {
        RestResponse response = RestContext.response;
        String token = RestContext.request.params.get('t');
        PDF_ESignature_Envelope__c env = PDFESignatureUtil.findEnvelopeByToken(token);
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
            response.responseBody = Blob.valueOf('Source PDF not found for envelope ' + String.valueOf(env.Id) + '. Verify PDF_ESignature_Source_Chunk__c rows exist for this envelope, or resend the envelope after v13 is deployed.');
            return;
        }
        response.statusCode = 200;
        response.addHeader('Content-Type', 'application/pdf');
        response.addHeader('Cache-Control', 'private, no-store, no-cache, max-age=0');
        response.addHeader('Content-Disposition', 'inline; filename="source.pdf"');
        response.responseBody = pdfData;
    }
}