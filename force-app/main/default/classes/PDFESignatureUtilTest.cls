@IsTest
private class PDFESignatureUtilTest {
    @IsTest
    static void estimatePageCountRecognizesCompactAndWhitespaceMarkers() {
        Blob pdfBlob = Blob.valueOf(
            '%PDF-1.4\n' +
            '1 0 obj << /Type/Pages /Count 3 >> endobj\n' +
            '2 0 obj << /Type/Page /Parent 1 0 R >> endobj\n' +
            '3 0 obj << /Type /Page /Parent 1 0 R >> endobj\n' +
            '4 0 obj << /Type\n/Page /Parent 1 0 R >> endobj\n' +
            '%%EOF'
        );

        System.assertEquals('3', PDFESignatureUtil.estimatePageCount(pdfBlob));
    }

    @IsTest
    static void estimatePageCountFallsBackToOneWhenNoPageMarkersExist() {
        Blob pdfBlob = Blob.valueOf('%PDF-1.4\n1 0 obj << /Type/Pages /Count 0 >> endobj\n%%EOF');

        System.assertEquals('1', PDFESignatureUtil.estimatePageCount(pdfBlob));
    }

    @IsTest
    static void getEnvelopeTitlePrefersStoredSourceContentVersionTitle() {
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Source_File_Title__c = 'Content Version Record Title'
        );

        System.assertEquals('Content Version Record Title', PDFESignatureUtil.getEnvelopeTitle(env));
    }

    @IsTest
    static void sourceFileHelpersCacheAndStampStatus() {
        Account parent = new Account(Name = 'Util Source Parent');
        insert parent;
        ContentVersion source = new ContentVersion(
            Title = 'Utility Source PDF',
            PathOnClient = 'Utility Source PDF.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF'),
            FirstPublishLocationId = parent.Id,
            E_Signature_File__c = true
        );
        insert source;
        source = [SELECT Id, ContentDocumentId, Title FROM ContentVersion WHERE Id = :source.Id];

        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Draft',
            Parent_Record_Id__c = String.valueOf(parent.Id)
        );
        insert env;
        insert new PDF_ESignature_Field__c(
            Envelope__c = env.Id,
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Content_Version_Id__c = String.valueOf(source.Id),
            Content_Document_Id__c = String.valueOf(source.ContentDocumentId),
            Field_Type__c = 'Signature',
            Label__c = 'Signature',
            Page_Number__c = 1,
            Required__c = true,
            Sequence__c = 1
        );

        System.assertEquals(source.Id, PDFESignatureUtil.getEnvelopeSourceVersionId(env.Id));
        System.assertEquals(source.ContentDocumentId, PDFESignatureUtil.getEnvelopeSourceDocumentId(env.Id));
        System.assertEquals(source.Id, PDFESignatureUtil.getContentVersionById(source.Id, false).Id);
        System.assertEquals(source.Id, PDFESignatureUtil.getContentVersionById(source.Id, true).Id);
        System.assertEquals(source.Id, PDFESignatureUtil.getLatestContentVersion(source.ContentDocumentId, false).Id);
        System.assertEquals(source.Id, PDFESignatureUtil.getLatestSourceVersion(new PDF_ESignature_Envelope__c(Id = env.Id), false).Id);

        Map<Id, Id> sourceByEnvelope = PDFESignatureUtil.getSourceDocumentIdsByEnvelopeId(new Set<Id>{ env.Id });
        System.assertEquals(source.ContentDocumentId, sourceByEnvelope.get(env.Id));
        Map<Id, String> titleByDocument = PDFESignatureUtil.getContentDocumentTitles(new Set<Id>{ source.ContentDocumentId });
        System.assertEquals('Utility Source PDF', titleByDocument.get(source.ContentDocumentId));
        System.assertEquals('Utility Source PDF', PDFESignatureUtil.getEnvelopeTitle(new PDF_ESignature_Envelope__c(Id = env.Id)));

        PDFESignatureUtil.cacheSourcePdfForEnvelope(env.Id);
        System.assert(PDFESignatureUtil.getCachedSourcePdfBlob(env.Id).toString().contains('%source'));

        PDFESignatureUtil.updateSourceFileESignatureStatus(new PDF_ESignature_Envelope__c(Id = env.Id), 'Sent');
        source = [SELECT E_Signature_Status__c FROM ContentVersion WHERE Id = :source.Id];
        System.assertEquals('Sent', source.E_Signature_Status__c);

        PDFESignatureUtil.audit(env.Id, 'Sent', UserInfo.getUserEmail(), 'Utility audit event.');
        System.assertEquals(1, [
            SELECT COUNT()
            FROM PDF_ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id
            AND Event_Type__c = 'Sent'
        ]);
    }

    @IsTest
    static void tokenUrlAndPrimitiveHelpersHandleCommonValues() {
        String token = PDFESignatureUtil.generateToken();
        System.assert(String.isNotBlank(token));
        String tokenHash = PDFESignatureUtil.hashToken(token);
        System.assertEquals(64, tokenHash.length());

        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Secure_Token_Hash__c = tokenHash,
            Signer_Email__c = 'signer@example.com'
        );
        insert env;
        System.assertEquals(env.Id, PDFESignatureUtil.findEnvelopeByToken(token).Id);

        System.assertEquals(12, PDFESignatureUtil.intValue('12', 0));
        System.assertEquals(4.5, PDFESignatureUtil.decimalValue('4.5', 0));
        System.assertEquals(true, PDFESignatureUtil.boolValue('yes', false));
        System.assertEquals(false, PDFESignatureUtil.boolValue('no', true));
        System.assertEquals('abc', PDFESignatureUtil.stringValue('abc'));
        System.assertEquals('&lt;abc&gt;', PDFESignatureUtil.escapeHtml('<abc>'));
        System.assertEquals('fallback', PDFESignatureUtil.firstNonBlank(new List<String>{ null, '', 'fallback' }));

        Account parent = new Account(Name = 'Util Id Parent');
        insert parent;
        System.assertEquals(parent.Id, PDFESignatureUtil.safeId(String.valueOf(parent.Id)));
        System.assertEquals(null, PDFESignatureUtil.safeId('not-an-id'));

        System.assertEquals('https://example.com/signatures', PDFESignatureUtil.normalizeBaseUrl('https://example.com/signatures/'));
        System.assertEquals(
            'https://example.com/signatures',
            PDFESignatureUtil.siteRootUrl('https://example.com/signatures/apex/PDFESignaturePage')
        );
        System.assertEquals('https://example.com/signatures/apex', PDFESignatureUtil.siteApexUrl('https://example.com/signatures'));
        System.assert(PDFESignatureUtil.buildPdfResourceUrl('abc 123').contains('abc'));
        System.assert(PDFESignatureUtil.buildPdfResourceUrl('abc 123').contains('123'));

        PDF_ESignature_Setting__mdt settings = PDFESignatureUtil.getSettings();
        System.assert(String.isNotBlank(PDFESignatureUtil.buildFinalizerCallbackUrl(settings)));
        if (!String.isBlank(settings.Site_Base_URL__c)) {
            System.assert(PDFESignatureUtil.buildSigningUrl('abc').contains('/PDFESignaturePage?t=abc'));
        }

        Map<String, Object> payload = new Map<String, Object>();
        PDFESignatureUtil.addCurrentRequestContext(payload);
        System.assert(payload.containsKey('serverTimestamp'));

        Test.startTest();
        PDFESignatureUtil.publishSignerCommand('Viewed', env, token, payload, false);
        Test.stopTest();
    }
}
