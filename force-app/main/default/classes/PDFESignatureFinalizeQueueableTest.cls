@IsTest
private class PDFESignatureFinalizeQueueableTest {
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            System.assertEquals('POST', req.getMethod(), 'Finalizer should POST to Power Automate.');
            System.assert(req.getBody().contains('stampOverlays'), 'Payload should include stampOverlays.');
            System.assert(req.getBody().contains('finalizerDebugText'), 'Payload should include finalizer debug text.');

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
        System.enqueueJob(new PDFESignatureFinalizeQueueable(envelopeId));
        Test.stopTest();

        PDF_ESignature_Envelope__c env = [
            SELECT Envelope_Status__c, Final_ContentVersion_Id__c, Final_ContentDocument_Id__c,
                   Completion_Message__c, Error_Message__c
            FROM PDF_ESignature_Envelope__c
            WHERE Id = :envelopeId
        ];
        System.assertEquals('Signed', env.Envelope_Status__c, 'Envelope should be completed when finalPdfBase64 is returned.');
        System.assertNotEquals(null, env.Final_ContentVersion_Id__c, 'Final ContentVersion Id should be stored.');
        System.assertNotEquals(null, env.Final_ContentDocument_Id__c, 'Final ContentDocument Id should be stored.');
        System.assertEquals(null, env.Error_Message__c, 'Successful finalization should clear error message.');
        System.assert(env.Completion_Message__c.contains('Finalizer debug:'), 'Completion message should include finalizer debug summary.');
        System.assert(env.Completion_Message__c.contains('stampOverlays='), 'Debug summary should include overlay count.');
    }

    @IsTest
    static void executeMarksErrorWhenSynchronousPdfMissing() {
        Id envelopeId = createEnvelopeWithSourceAndSignatureField();
        Test.setMock(HttpCalloutMock.class, new MissingPdfMock());

        Test.startTest();
        System.enqueueJob(new PDFESignatureFinalizeQueueable(envelopeId));
        Test.stopTest();

        PDF_ESignature_Envelope__c env = [
            SELECT Envelope_Status__c, Final_ContentVersion_Id__c, Final_ContentDocument_Id__c,
                   Completion_Message__c, Error_Message__c
            FROM PDF_ESignature_Envelope__c
            WHERE Id = :envelopeId
        ];
        System.assertEquals('Error', env.Envelope_Status__c, 'Missing finalPdfBase64 should put the envelope in Error.');
        System.assertEquals(null, env.Final_ContentVersion_Id__c, 'No final file should be stored when finalPdfBase64 is missing.');
        System.assert(env.Error_Message__c.contains('finalPdfBase64'), 'Error should clearly identify missing finalPdfBase64.');
        System.assert(env.Error_Message__c.contains('Finalizer debug:'), 'Error should include finalizer debug summary.');
    }

    private static Id createEnvelopeWithSourceAndSignatureField() {
        PDF_ESignature_Envelope__c env = new PDF_ESignature_Envelope__c(
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
            Value__c = 'Derek Hawley',
            Completed__c = true,
            Completed_At__c = System.now(),
            Required__c = true,
            Sequence__c = 1
        );
        return env.Id;
    }
}