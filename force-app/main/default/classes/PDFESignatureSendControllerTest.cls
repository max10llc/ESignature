@IsTest
private class PDFESignatureSendControllerTest {
    private class DraftFixture {
        Id parentId;
        PDF_ESignature_Envelope__c envelope;
        PDF_ESignature_Field__c field;
    }

    @IsTest
    static void getDraftEnvelopesReturnsCurrentDraftsWithRefreshKey() {
        DraftFixture fixture = createDraftFixture();

        List<PDFESignatureSendController.EnvelopeDTO> drafts =
            PDFESignatureSendController.getDraftEnvelopes(String.valueOf(fixture.parentId), 'first-refresh');

        System.assertEquals(1, drafts.size(), 'One draft envelope should be returned.');
        System.assertEquals(String.valueOf(fixture.envelope.Id), drafts[0].id);
        System.assertEquals('Draft', drafts[0].status);
        System.assertEquals(1, drafts[0].fieldCount);
        System.assertEquals('Send Controller Source', drafts[0].title);
    }

    @IsTest
    static void sendEnvelopeUpdatesDraftAndCachesSourcePdf() {
        DraftFixture fixture = createDraftFixture();

        Test.startTest();
        PDFESignatureSendController.SendResultDTO result = PDFESignatureSendController.sendEnvelope(
            String.valueOf(fixture.envelope.Id),
            'Derek Hawley',
            'signer@example.com',
            'President',
            30
        );
        Test.stopTest();

        System.assertEquals(String.valueOf(fixture.envelope.Id), result.envelopeId);
        System.assertEquals('Sent', result.status);
        System.assert(result.signingUrl.contains('/PDFESignaturePage?t='), 'Result should include a public signing URL.');

        PDF_ESignature_Envelope__c env = [
            SELECT Envelope_Status__c, Signer_Name__c, Signer_Email__c, Signer_Title__c,
                   Sent_At__c, Expires_At__c, Public_Signing_URL__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM PDF_ESignature_Envelope__c
            WHERE Id = :fixture.envelope.Id
        ];
        System.assertEquals('Sent', env.Envelope_Status__c);
        System.assertEquals('Derek Hawley', env.Signer_Name__c);
        System.assertEquals('signer@example.com', env.Signer_Email__c);
        System.assertEquals('President', env.Signer_Title__c);
        System.assertNotEquals(null, env.Sent_At__c);
        System.assertNotEquals(null, env.Expires_At__c);
        System.assertNotEquals(null, env.Public_Signing_URL__c);
        System.assertEquals('Send Controller Source', env.Source_File_Title__c);
        System.assertEquals(fixture.field.Content_Version_Id__c, env.Source_ContentVersion_Id__c);
        System.assertEquals(fixture.field.Content_Document_Id__c, env.Source_ContentDocument_Id__c);

        System.assertEquals(1, [
            SELECT COUNT()
            FROM PDF_ESignature_Source_Chunk__c
            WHERE Envelope__c = :fixture.envelope.Id
        ], 'Source PDF should be cached for public signing.');
        System.assertEquals(1, [
            SELECT COUNT()
            FROM PDF_ESignature_Audit_Event__c
            WHERE Envelope__c = :fixture.envelope.Id
            AND Event_Type__c = 'Sent'
        ], 'Sent audit event should be written.');
    }

    @IsTest
    static void sendEnvelopeRejectsDraftWithoutFields() {
        Account parent = new Account(Name = 'Send Controller No Fields');
        insert parent;
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Draft',
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Parent_Object_Api_Name__c = 'Account'
        );
        insert env;

        try {
            PDFESignatureSendController.sendEnvelope(String.valueOf(env.Id), 'Derek Hawley', 'signer@example.com', null, 30);
            System.assert(false, 'Expected sendEnvelope to reject a draft without fields.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage(), 'An AuraHandledException should be thrown.');
        }
    }

    @IsTest
    static void signatureRequestEmailUsesOriginalPackageFormat() {
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Signer_Name__c = 'Derek Hawley',
            Expires_At__c = Datetime.newInstance(2026, 7, 27, 12, 0, 0)
        );

        String html = PDFESignatureSendController.buildSignatureRequestEmailHtml(
            env,
            'https://example.com/sign?t=abc123',
            'Special Services Agreement'
        );

        System.assert(html.contains('<table role="presentation" width="100%"'), 'Email should use the original table-based shell.');
        System.assert(html.contains('/resource/Kaizon_Solutions_Logo'), 'Email should include the Kaizon logo static resource.');
        System.assert(html.contains('has sent you a document that requires your signature'), 'Email should include the original request language.');
        System.assert(html.contains('Special Services Agreement'), 'Email should include the document title block.');
        System.assert(html.contains('Review &amp; Sign Document'), 'Email should include the original call-to-action label.');
        System.assert(html.contains('This link is unique to you and will expire on'), 'Email should include the expiration notice.');
        System.assert(html.contains('https://example.com/sign?t=abc123'), 'Email should include the fallback signing URL.');
    }

    private static DraftFixture createDraftFixture() {
        Account parent = new Account(Name = 'Send Controller Parent');
        insert parent;

        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
            Envelope_Status__c = 'Draft',
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Parent_Object_Api_Name__c = 'Account'
        );
        insert env;

        ContentVersion source = new ContentVersion(
            Title = 'Send Controller Source',
            PathOnClient = 'Send Controller Source.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF')
        );
        insert source;
        source = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id];

        PDF_ESignature_Field__c field = new PDF_ESignature_Field__c(
            Envelope__c = env.Id,
            Parent_Record_Id__c = String.valueOf(parent.Id),
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
        insert field;

        DraftFixture fixture = new DraftFixture();
        fixture.parentId = parent.Id;
        fixture.envelope = env;
        fixture.field = field;
        return fixture;
    }
}
