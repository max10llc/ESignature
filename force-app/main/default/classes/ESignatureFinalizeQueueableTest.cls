@IsTest
private class ESignatureFinalizeQueueableTest {
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            System.assertEquals('POST', req.getMethod(), 'Finalizer should POST to Power Automate.');
            System.assert(req.getBody().contains('stampOverlays'), 'Payload should include stampOverlays.');
            System.assert(req.getBody().contains('finalizerDebugText'), 'Payload should include finalizer debug text.');
            System.assert(req.getBody().contains('auditReportPdfBase64'), 'Payload should include the final audit report PDF.');

            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
            System.assertEquals(true, (Boolean) payload.get('appendAuditReport'), 'Payload should ask the finalizer to append the audit report.');
            System.assertEquals(payload.get('auditReportPdfBase64'), payload.get('certificatePdfBase64'), 'Certificate alias should match the audit report PDF for finalizer compatibility.');
            String auditReportPdfBase64 = (String) payload.get('auditReportPdfBase64');
            System.assert(String.isNotBlank(auditReportPdfBase64), 'Audit report base64 should be populated.');
            String auditReportText = EncodingUtil.base64Decode(auditReportPdfBase64).toString();
            System.assert(auditReportText.startsWith('%PDF-1.4'), 'Audit report should be a PDF.');
            System.assert(auditReportText.contains('Final Audit Report'), 'Audit report should include the report heading.');
            System.assert(auditReportText.contains('Queueable Source Test'), 'Audit report should use the source file title.');

            String finalPdfBase64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4\n%final\n%%EOF'));
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success' => true,
                'finalPdfBase64' => finalPdfBase64,
                'fileName' => 'Final Test Signed.pdf',
                'message' => 'Final signed PDF generated.'
            }));
            return res;
        }
    }

    private class MissingPdfMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success' => true,
                'message' => 'Accepted but no PDF.'
            }));
            return res;
        }
    }

    @IsTest
    static void executeCompletesEnvelopeWhenSynchronousPdfReturned() {
        Id envelopeId = createEnvelopeWithSourceAndSignatureField();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        System.enqueueJob(new ESignatureFinalizeQueueable(envelopeId));
        Test.stopTest();

        ESignature_Envelope__c env = [
            SELECT Envelope_Status__c, Final_ContentVersion_Id__c, Final_ContentDocument_Id__c,
                   Completion_Message__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :envelopeId
        ];
        System.assertEquals('Signed', env.Envelope_Status__c, 'Envelope should be completed when finalPdfBase64 is returned.');
        System.assertNotEquals(null, env.Final_ContentVersion_Id__c, 'Final ContentVersion Id should be stored.');
        System.assertNotEquals(null, env.Final_ContentDocument_Id__c, 'Final ContentDocument Id should be stored.');
        System.assertEquals(null, env.Error_Message__c, 'Successful finalization should clear error message.');
        System.assert(env.Completion_Message__c.contains('Finalizer debug:'), 'Completion message should include finalizer debug summary.');
        System.assert(env.Completion_Message__c.contains('stampOverlays='), 'Debug summary should include overlay count.');
        ESignature_Field__c sourceField = [
            SELECT Content_Version_Id__c
            FROM ESignature_Field__c
            WHERE Envelope__c = :envelopeId
            LIMIT 1
        ];
        Id sourceVersionId = ESignatureUtil.safeId(sourceField.Content_Version_Id__c);
        ContentVersion sourceVersion = [
            SELECT ESignature_Status__c
            FROM ContentVersion
            WHERE Id = :sourceVersionId
        ];
        Id finalVersionId = ESignatureUtil.safeId(env.Final_ContentVersion_Id__c);
        ContentVersion finalVersion = [
            SELECT ESignature_Status__c
            FROM ContentVersion
            WHERE Id = :finalVersionId
        ];
        System.assertEquals('Completed', sourceVersion.ESignature_Status__c, 'Finalization should mark the source file completed.');
        System.assertEquals('Completed', finalVersion.ESignature_Status__c, 'Finalization should mark the final signed file completed.');
    }

    @IsTest
    static void executeMarksErrorWhenSynchronousPdfMissing() {
        Id envelopeId = createEnvelopeWithSourceAndSignatureField();
        Test.setMock(HttpCalloutMock.class, new MissingPdfMock());

        Test.startTest();
        System.enqueueJob(new ESignatureFinalizeQueueable(envelopeId));
        Test.stopTest();

        ESignature_Envelope__c env = [
            SELECT Envelope_Status__c, Final_ContentVersion_Id__c, Final_ContentDocument_Id__c,
                   Completion_Message__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :envelopeId
        ];
        System.assertEquals('Error', env.Envelope_Status__c, 'Missing finalPdfBase64 should put the envelope in Error.');
        System.assertEquals(null, env.Final_ContentVersion_Id__c, 'No final file should be stored when finalPdfBase64 is missing.');
        System.assert(env.Error_Message__c.contains('finalPdfBase64'), 'Error should clearly identify missing finalPdfBase64.');
        System.assert(env.Error_Message__c.contains('Finalizer debug:'), 'Error should include finalizer debug summary.');
    }

    @IsTest
    static void finalizerServiceCompletesExistingFileAndMarksErrors() {
        Account parent = new Account(Name = 'Finalizer Service Parent');
        insert parent;
        ContentVersion source = new ContentVersion(
            Title = 'Finalizer Service Source',
            PathOnClient = 'Finalizer Service Source.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF'),
            FirstPublishLocationId = parent.Id,
            ESignature_File__c = true
        );
        insert source;
        source = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id];

        ContentVersion finalFile = new ContentVersion(
            Title = 'Existing Final Signed File',
            PathOnClient = 'Existing Final Signed File.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%final\n%%EOF'),
            FirstPublishLocationId = parent.Id
        );
        insert finalFile;
        finalFile = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :finalFile.Id];

        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = 'Sent',
            Parent_Record_Id__c = String.valueOf(parent.Id),
            Signer_Email__c = 'signer@example.com',
            Source_ContentVersion_Id__c = String.valueOf(source.Id),
            Source_ContentDocument_Id__c = String.valueOf(source.ContentDocumentId)
        );
        insert env;

        ESignatureFinalizerService.markAccepted(env.Id, 'request-123', 'Accepted for finalization.');
        env = [SELECT Envelope_Status__c, Finalizer_Request_Id__c, Completion_Message__c FROM ESignature_Envelope__c WHERE Id = :env.Id];
        System.assertEquals('Finalizing', env.Envelope_Status__c);
        System.assertEquals('request-123', env.Finalizer_Request_Id__c);
        System.assertEquals('Accepted for finalization.', env.Completion_Message__c);

        ESignatureFinalizerService.completeWithExistingFile(env.Id, finalFile.Id, null, 'Final file attached.');
        env = [
            SELECT Envelope_Status__c, Final_ContentVersion_Id__c, Final_ContentDocument_Id__c, Completion_Message__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('Signed', env.Envelope_Status__c);
        System.assertEquals(String.valueOf(finalFile.Id), env.Final_ContentVersion_Id__c);
        System.assertEquals(String.valueOf(finalFile.ContentDocumentId), env.Final_ContentDocument_Id__c);
        System.assertEquals('Final file attached.', env.Completion_Message__c);
        System.assertEquals(null, env.Error_Message__c);

        source = [SELECT ESignature_Status__c FROM ContentVersion WHERE Id = :source.Id];
        finalFile = [SELECT ESignature_Status__c FROM ContentVersion WHERE Id = :finalFile.Id];
        System.assertEquals('Completed', source.ESignature_Status__c);
        System.assertEquals('Completed', finalFile.ESignature_Status__c);
        System.assertEquals('Signed Document', ESignatureFinalizerService.titleFromFileName('Signed Document.pdf'));
        System.assertEquals('Signed Document.pdf', ESignatureFinalizerService.resolveFileName(env, 'Signed Document'));

        ESignatureFinalizerService.markError(env.Id, 'Something went wrong.');
        env = [SELECT Envelope_Status__c, Error_Message__c FROM ESignature_Envelope__c WHERE Id = :env.Id];
        System.assertEquals('Error', env.Envelope_Status__c);
        System.assertEquals('Something went wrong.', env.Error_Message__c);
    }

    private static Id createEnvelopeWithSourceAndSignatureField() {
        ESignature_Envelope__c env = new ESignature_Envelope__c(
            Envelope_Status__c = 'Signed',
            Parent_Object_Api_Name__c = 'Opportunity',
            Signer_Name__c = 'Derek Hawley',
            Signer_Email__c = 'derek.hawley@example.com',
            Signer_Title__c = 'President',
            Signed_At__c = System.now(),
            Signature_Method__c = 'Typed',
            Signature_Image_Data_Url__c = 'data:image/png;base64,abc'
        );
        insert env;

        ContentVersion source = new ContentVersion(
            Title = 'Queueable Source Test',
            PathOnClient = 'Queueable Source Test.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%source\n%%EOF'),
            ESignature_File__c = true
        );
        insert source;
        source = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id];

        insert new ESignature_Field__c(
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
            Value__c = 'Derek Hawley',
            Completed__c = true,
            Completed_At__c = System.now(),
            Required__c = true,
            Sequence__c = 1
        );
        insert new ESignature_Audit_Event__c(
            Envelope__c = env.Id,
            Event_Type__c = 'Sent',
            Occurred_At__c = System.now().addMinutes(-10),
            Actor_Email__c = UserInfo.getUserEmail(),
            Details__c = 'Envelope sent to derek.hawley@example.com.',
            IP_Address__c = '203.0.113.10',
            User_Agent__c = 'Unit Test'
        );
        return env.Id;
    }
}
