@IsTest
private class ESignatureSendEnvelopeActionTest {
    @IsTest
    static void sendActionSendsLatestDraftByParentRecordAndContact() {
        DraftFixture fixture = createDraftFixture('Flow Parent Source');
        Contact signer = new Contact(
            AccountId = fixture.parentId,
            LastName = 'Signer',
            Email = 'flow.signer@example.com',
            Title = 'Operations Manager'
        );
        insert signer;

        ESignatureSendEnvelopeAction.Request request = new ESignatureSendEnvelopeAction.Request();
        request.parentRecordId = String.valueOf(fixture.parentId);
        request.signerContactId = String.valueOf(signer.Id);
        request.requestSubject = 'Flow-sent signature request';
        request.requestMessage = 'Please sign this from the Flow action.';
        request.expirationDays = 21;

        Test.startTest();
        List<ESignatureSendEnvelopeAction.Response> responses =
            ESignatureSendEnvelopeAction.sendEnvelopes(new List<ESignatureSendEnvelopeAction.Request>{ request });
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'One Flow request should return one response.');
        System.assertEquals(true, responses[0].success, responses[0].message);
        System.assertEquals(String.valueOf(fixture.envelope.Id), responses[0].envelopeId);
        System.assertEquals('Sent', responses[0].status);
        System.assertEquals('flow.signer@example.com', responses[0].signerEmail);
        System.assertEquals(null, responses[0].signingUrl, 'Flow action should not return the signing URL.');

        ESignature_Envelope__c sent = [
            SELECT Status__c, Signer_Name__c, Signer_Email__c, Signer_Title__c,
                   Request_Subject__c, Request_Message__c, Secure_Token_Hash__c, Public_Signing_URL__c
            FROM ESignature_Envelope__c
            WHERE Id = :fixture.envelope.Id
        ];
        System.assertEquals('Sent', sent.Status__c);
        System.assertEquals('Signer', sent.Signer_Name__c);
        System.assertEquals('flow.signer@example.com', sent.Signer_Email__c);
        System.assertEquals('Operations Manager', sent.Signer_Title__c);
        System.assertEquals('Flow-sent signature request', sent.Request_Subject__c);
        System.assertEquals('Please sign this from the Flow action.', sent.Request_Message__c);
        System.assertNotEquals(null, sent.Secure_Token_Hash__c);
        System.assertEquals(null, sent.Public_Signing_URL__c, 'The raw public signing URL should not be stored on the envelope.');
    }

    @IsTest
    static void sendActionUsesEnvelopeRecordAndFlowOverridesContact() {
        DraftFixture fixture = createDraftFixture('Flow Override Source');
        Contact signer = new Contact(
            AccountId = fixture.parentId,
            LastName = 'Original',
            Email = 'original.signer@example.com',
            Title = 'Original Title'
        );
        insert signer;

        ESignatureSendEnvelopeAction.Request request = new ESignatureSendEnvelopeAction.Request();
        request.envelopeRecord = fixture.envelope;
        request.signerContactId = String.valueOf(signer.Id);
        request.signerName = 'Flow Override';
        request.signerEmail = 'override.signer@example.com';
        request.signerTitle = 'Override Title';
        request.requestSubject = 'Override subject';
        request.requestMessage = 'Override message';

        Test.startTest();
        List<ESignatureSendEnvelopeAction.Response> responses =
            ESignatureSendEnvelopeAction.sendEnvelopes(new List<ESignatureSendEnvelopeAction.Request>{ request });
        Test.stopTest();

        System.assertEquals(true, responses[0].success, responses[0].message);
        ESignature_Envelope__c sent = [
            SELECT Signer_Name__c, Signer_Email__c, Signer_Title__c, Request_Subject__c
            FROM ESignature_Envelope__c
            WHERE Id = :fixture.envelope.Id
        ];
        System.assertEquals('Flow Override', sent.Signer_Name__c);
        System.assertEquals('override.signer@example.com', sent.Signer_Email__c);
        System.assertEquals('Override Title', sent.Signer_Title__c);
        System.assertEquals('Override subject', sent.Request_Subject__c);
    }

    @IsTest
    static void sendActionReturnsFailureWhenNoDraftFound() {
        Account parent = new Account(Name = 'No Draft Flow Parent');
        insert parent;

        ESignatureSendEnvelopeAction.Request request = new ESignatureSendEnvelopeAction.Request();
        request.parentRecordId = String.valueOf(parent.Id);
        request.signerName = 'Missing Draft';
        request.signerEmail = 'missing.draft@example.com';
        request.requestSubject = 'Missing draft subject';

        Test.startTest();
        List<ESignatureSendEnvelopeAction.Response> responses =
            ESignatureSendEnvelopeAction.sendEnvelopes(new List<ESignatureSendEnvelopeAction.Request>{ request });
        Test.stopTest();

        System.assertEquals(1, responses.size());
        System.assertEquals(false, responses[0].success);
        System.assertEquals('No draft E-Signature Envelope was found to send.', responses[0].message);
    }

    private class DraftFixture {
        Id parentId;
        ESignature_Envelope__c envelope;
        ESignature_Field__c field;
    }

    private static DraftFixture createDraftFixture(String sourceTitle) {
        Account parent = new Account(Name = sourceTitle + ' Parent');
        insert parent;

        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Status__c = 'Draft',
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Parent_Object_Api_Name__c = 'Account'
        );
        insert env;

        ContentVersion source = new ContentVersion(
            Title = sourceTitle,
            PathOnClient = sourceTitle + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF'),
            ESignature_File__c = true
        );
        insert source;
        source = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id];

        ESignature_Field__c field = new ESignature_Field__c(
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
