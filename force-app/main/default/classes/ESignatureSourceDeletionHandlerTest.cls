@IsTest
private class ESignatureSourceDeletionHandlerTest {
    private static ContentVersion sourceFile(String title) {
        ContentVersion source = new ContentVersion(
            Title = title, PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF')
        );
        insert source;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id];
    }

    private static ESignature_Envelope__c envelope(ContentVersion source, String token, String status) {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Source_ContentDocument_Id__c = String.valueOf(source.ContentDocumentId),
            Source_ContentVersion_Id__c = String.valueOf(source.Id),
            Source_File_Title__c = 'Deletion regression',
            Secure_Token_Hash__c = ESignatureUtil.hashToken(token),
            Signer_Name__c = 'Test Signer', Signer_Email__c = 'signer@example.com',
            Status__c = status
        );
        insert env;
        return env;
    }

    @IsTest
    static void deletionBlocksCachedPdfAndAlreadyOpenSigningPage() {
        ContentVersion source = sourceFile('Deleted agreement');
        String token = 'delete-open-signing-page';
        ESignature_Envelope__c env = envelope(source, token, 'Viewed');
        insert new ESignature_Field__c(
            Envelope__c = env.Id, Field_Type__c = 'Text', Page_Number__c = 1,
            Content_Version_Id__c = String.valueOf(source.Id),
            Content_Document_Id__c = String.valueOf(source.ContentDocumentId)
        );
        ESignatureUtil.cacheSourcePdfForEnvelope(env.Id);
        Test.setCurrentPage(Page.ESignaturePage);
        ApexPages.currentPage().getParameters().put('t', token);
        ESignaturePageController controller = new ESignaturePageController();
        System.assertEquals(true, controller.getCanSign());
        controller.consent = true;
        controller.disclosureAccepted = true;
        controller.signerFieldsJson = '[]';

        Test.startTest();
        delete new ContentDocument(Id = source.ContentDocumentId);
        controller.sign();
        RestContext.request = new RestRequest();
        RestContext.request.params.put('t', token);
        RestContext.response = new RestResponse();
        ESignaturePdfResource.getPdf();
        Test.stopTest();

        System.assertEquals(false, controller.getCanSign());
        System.assertEquals('Document Unavailable', controller.getTerminalTitle());
        System.assert(controller.pageMessage.contains('sender deleted it'));
        System.assertEquals(410, RestContext.response.statusCode, 'Cached PDF must no longer be served.');
        env = [SELECT Status__c, Signed_At__c FROM ESignature_Envelope__c WHERE Id = :env.Id];
        System.assertEquals('Canceled', env.Status__c);
        System.assertEquals(null, env.Signed_At__c);
        System.assertEquals(0, [SELECT COUNT() FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :env.Id AND Event_Type__c = 'Signed']);
    }

    @IsTest
    static void deletionClosesBulkAndLegacyRequestsButPreservesOtherDocuments() {
        ContentVersion deletedSource = sourceFile('Bulk deleted agreement');
        ContentVersion retainedSource = sourceFile('Retained agreement');
        List<ESignature_Envelope__c> requests = new List<ESignature_Envelope__c>();
        for (Integer i = 0; i < 200; i++) {
            requests.add(new ESignature_Envelope__c(
                Source_ContentDocument_Id__c = String.valueOf(deletedSource.ContentDocumentId),
                Status__c = 'Sent'
            ));
        }
        insert requests;
        ESignature_Envelope__c retained = envelope(retainedSource, 'retained', 'Viewed');
        ESignature_Envelope__c completed = envelope(deletedSource, 'completed', 'Signed');
        completed.Signed_At__c = System.now();
        update completed;
        ESignature_Envelope__c legacy = new ESignature_Envelope__c(Status__c = 'Sent');
        insert legacy;
        insert new ESignature_Field__c(
            Envelope__c = legacy.Id, Field_Type__c = 'Text', Page_Number__c = 1,
            Content_Document_Id__c = String.valueOf(deletedSource.ContentDocumentId)
        );

        Test.startTest();
        delete new ContentDocument(Id = deletedSource.ContentDocumentId);
        Test.stopTest();

        System.assertEquals(201, [SELECT COUNT() FROM ESignature_Envelope__c WHERE Status__c = 'Canceled']);
        System.assertEquals('Viewed', [SELECT Status__c FROM ESignature_Envelope__c WHERE Id = :retained.Id].Status__c);
        System.assertEquals('Signed', [SELECT Status__c FROM ESignature_Envelope__c WHERE Id = :completed.Id].Status__c);
    }

    @IsTest
    static void queuedSignatureCannotReopenDeletedRequest() {
        ContentVersion source = sourceFile('Queued deleted agreement');
        String token = 'queued-delete';
        ESignature_Envelope__c env = envelope(source, token, 'Viewed');
        Test.startTest();
        EventBus.publish(new ESignature_Command__e(
            Action__c = 'Signed', Token_Hash__c = ESignatureUtil.hashToken(token),
            Payload_JSON__c = '{"typedName":"Test Signer","signerFieldsJson":"[]"}'
        ));
        delete new ContentDocument(Id = source.ContentDocumentId);
        Test.getEventBus().deliver();
        Test.stopTest();
        env = [SELECT Status__c, Signed_At__c FROM ESignature_Envelope__c WHERE Id = :env.Id];
        System.assertEquals('Canceled', env.Status__c);
        System.assertEquals(null, env.Signed_At__c);
    }
}
