@IsTest
private class PDFESignaturePdfResourceTest {
    @IsTest
    static void getPdfUsesSalesforceDocumentTitleAsFilename() {
        String token = 'pdf-resource-token';
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Viewed',
            Secure_Token_Hash__c = PDFESignatureUtil.hashToken(token),
            Signer_Name__c = 'Derek Hawley',
            Signer_Email__c = 'signer@example.com',
            Signer_Title__c = 'President'
        );
        insert env;

        ContentVersion source = new ContentVersion(
            Title = 'Salesforce Saved Document',
            PathOnClient = 'Salesforce Saved Document.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF')
        );
        insert source;
        source = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id];

        insert new PDF_ESignature_Field__c(
            Envelope__c = env.Id,
            Content_Version_Id__c = String.valueOf(source.Id),
            Content_Document_Id__c = String.valueOf(source.ContentDocumentId),
            Field_Type__c = 'Signature',
            Label__c = 'Signature',
            Page_Number__c = 1,
            Pdf_X__c = 100,
            Pdf_Y__c = 200,
            Pdf_Width__c = 180,
            Pdf_Height__c = 32,
            Page_Width_Points__c = 612,
            Page_Height_Points__c = 792,
            Required__c = true,
            Sequence__c = 1
        );

        RestRequest request = new RestRequest();
        request.requestUri = '/services/apexrest/PDFESign/v1/pdf';
        request.httpMethod = 'GET';
        request.params.put('t', token);
        RestContext.request = request;
        RestContext.response = new RestResponse();

        PDFESignaturePdfResource.getPdf();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('inline; filename="Salesforce Saved Document.pdf"', RestContext.response.headers.get('Content-Disposition'));
        System.assertEquals('application/pdf', RestContext.response.headers.get('Content-Type'));
        System.assertNotEquals(null, RestContext.response.responseBody);
    }

    @IsTest
    static void getPdfReturnsNotFoundForInvalidToken() {
        setRestRequest('missing-token');

        PDFESignaturePdfResource.getPdf();

        System.assertEquals(404, RestContext.response.statusCode);
        System.assertEquals('Document not found.', RestContext.response.responseBody.toString());
    }

    @IsTest
    static void getPdfReturnsForbiddenForExpiredEnvelope() {
        String token = 'pdf-resource-expired-token';
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Viewed',
            Secure_Token_Hash__c = PDFESignatureUtil.hashToken(token),
            Signer_Email__c = 'signer@example.com',
            Expires_At__c = System.now().addMinutes(-5)
        );
        insert env;
        setRestRequest(token);

        PDFESignaturePdfResource.getPdf();

        System.assertEquals(403, RestContext.response.statusCode);
        System.assertEquals('This signing link has expired.', RestContext.response.responseBody.toString());
    }

    @IsTest
    static void getPdfReturnsGoneForCompletedEnvelope() {
        String token = 'pdf-resource-completed-token';
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Signed',
            Secure_Token_Hash__c = PDFESignatureUtil.hashToken(token),
            Signer_Email__c = 'signer@example.com',
            Signed_At__c = System.now()
        );
        insert env;
        setRestRequest(token);

        PDFESignaturePdfResource.getPdf();

        System.assertEquals(410, RestContext.response.statusCode);
        System.assertEquals('text/plain; charset=UTF-8', RestContext.response.headers.get('Content-Type'));
        System.assertEquals('This document has already been completed.', RestContext.response.responseBody.toString());
    }

    @IsTest
    static void getPdfReturnsGoneForCancelledEnvelope() {
        String token = 'pdf-resource-cancelled-token';
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Canceled',
            Secure_Token_Hash__c = PDFESignatureUtil.hashToken(token),
            Signer_Email__c = 'signer@example.com'
        );
        insert env;
        setRestRequest(token);

        PDFESignaturePdfResource.getPdf();

        System.assertEquals(410, RestContext.response.statusCode);
        System.assertEquals('text/plain; charset=UTF-8', RestContext.response.headers.get('Content-Type'));
        System.assertEquals('This document has already been cancelled.', RestContext.response.responseBody.toString());
    }

    @IsTest
    static void getPdfReturnsGoneForDeclinedEnvelope() {
        String token = 'pdf-resource-declined-token';
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Viewed',
            Secure_Token_Hash__c = PDFESignatureUtil.hashToken(token),
            Signer_Email__c = 'signer@example.com',
            Decline_Reason__c = 'Signer declined from prompt.'
        );
        insert env;
        setRestRequest(token);

        PDFESignaturePdfResource.getPdf();

        System.assertEquals(410, RestContext.response.statusCode);
        System.assertEquals('text/plain; charset=UTF-8', RestContext.response.headers.get('Content-Type'));
        System.assertEquals('This document has already been declined.', RestContext.response.responseBody.toString());
    }

    @IsTest
    static void getPdfReturnsNotFoundWhenSourcePdfIsMissing() {
        String token = 'pdf-resource-no-source-token';
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Viewed',
            Secure_Token_Hash__c = PDFESignatureUtil.hashToken(token),
            Signer_Email__c = 'signer@example.com'
        );
        insert env;
        setRestRequest(token);

        PDFESignaturePdfResource.getPdf();

        System.assertEquals(404, RestContext.response.statusCode);
        System.assertEquals('text/plain; charset=UTF-8', RestContext.response.headers.get('Content-Type'));
        System.assert(RestContext.response.responseBody.toString().contains('Source PDF not found'));
    }

    private static void setRestRequest(String token) {
        RestRequest request = new RestRequest();
        request.requestUri = '/services/apexrest/PDFESign/v1/pdf';
        request.httpMethod = 'GET';
        request.params.put('t', token);
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }
}
