@IsTest
private class PDFESignaturePrepareControllerTest {
    @IsTest
    static void getRecordPdfFilesReturnsOnlyMarkedPdfFiles() {
        Account parent = new Account(Name = 'Prepare Controller Parent');
        insert parent;
        ContentVersion eligible = createPdfFile(parent.Id, 'Eligible E-Signature File', true);
        createPdfFile(parent.Id, 'Regular PDF File', false);

        List<PDFESignaturePrepareController.RecordFileDTO> files =
            PDFESignaturePrepareController.getRecordPdfFiles(parent.Id);

        System.assertEquals(1, files.size(), 'Only files marked as E-Signature File should be returned.');
        System.assertEquals(String.valueOf(eligible.ContentDocumentId), files[0].contentDocumentId);
        System.assertEquals(String.valueOf(eligible.Id), files[0].contentVersionId);
    }

    @IsTest
    static void getPdfDocumentInfoRejectsUnmarkedPdf() {
        Account parent = new Account(Name = 'Prepare Controller Unmarked Parent');
        insert parent;
        ContentVersion source = createPdfFile(parent.Id, 'Unmarked PDF File', false);

        try {
            PDFESignaturePrepareController.getPdfDocumentInfo(String.valueOf(source.ContentDocumentId));
            System.assert(false, 'Expected unmarked PDF to be rejected.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage(), 'The caller should receive a clear AuraHandledException.');
        }
    }

    @IsTest
    static void getPdfDocumentInfoReturnsMarkedPdfInfo() {
        Account parent = new Account(Name = 'Prepare Controller Marked Parent');
        insert parent;
        ContentVersion source = createPdfFile(parent.Id, 'Marked PDF File', true);

        PDFESignaturePrepareController.PdfInfoDTO info =
            PDFESignaturePrepareController.getPdfDocumentInfo(String.valueOf(source.ContentDocumentId));

        System.assertEquals(String.valueOf(source.ContentDocumentId), info.contentDocumentId);
        System.assertEquals(String.valueOf(source.Id), info.contentVersionId);
        System.assertEquals('Marked PDF File', info.title);
        System.assertEquals('pdf', info.fileExtension);
        System.assertEquals(1, info.pageCount);
    }

    @IsTest
    static void savePlacementsCreatesDraftForMarkedPdf() {
        Account parent = new Account(Name = 'Prepare Controller Save Parent');
        insert parent;
        ContentVersion source = createPdfFile(parent.Id, 'Prepared E-Signature File', true);

        String placementsJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'fieldType' => 'Signature',
                'pageNumber' => 1,
                'xPercent' => 0.10,
                'yPercent' => 0.20,
                'widthPercent' => 0.25,
                'heightPercent' => 0.05,
                'signerNumber' => 1,
                'required' => true,
                'label' => 'Signature'
            }
        });

        PDFESignaturePrepareController.SaveResultDTO result = PDFESignaturePrepareController.savePlacements(
            String.valueOf(parent.Id),
            String.valueOf(source.ContentDocumentId),
            String.valueOf(source.Id),
            placementsJson
        );

        System.assertNotEquals(null, result.envelopeId, 'Saving placements should create or update a draft envelope.');
        ESignature_Envelope__c env = [
            SELECT Envelope_Status__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c, Source_File_Title__c,
                   Parent_Record_Id__c, Parent_Object_Api_Name__c, Account__c, Opportunity__c, Work_Order__c
            FROM ESignature_Envelope__c
            WHERE Id = :result.envelopeId
        ];
        System.assertEquals('Draft', env.Envelope_Status__c);
        System.assertEquals(String.valueOf(parent.Id), env.Parent_Record_Id__c);
        System.assertEquals('Account', env.Parent_Object_Api_Name__c);
        System.assertEquals(parent.Id, env.Account__c);
        System.assertEquals(null, env.Opportunity__c);
        System.assertEquals(null, env.Work_Order__c);
        System.assertEquals(String.valueOf(source.Id), env.Source_ContentVersion_Id__c);
        System.assertEquals(String.valueOf(source.ContentDocumentId), env.Source_ContentDocument_Id__c);
        System.assertEquals('Prepared E-Signature File', env.Source_File_Title__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM ESignature_Field__c
            WHERE Envelope__c = :env.Id
        ]);

        List<PDFESignaturePrepareController.PlacementDTO> placements =
            PDFESignaturePrepareController.getPlacements(String.valueOf(parent.Id), String.valueOf(source.ContentDocumentId));
        System.assertEquals(1, placements.size(), 'Saved draft placements should be returned.');
        System.assertEquals('Signature', placements[0].fieldType);
        System.assertEquals(1, placements[0].pageNumber);
        System.assertEquals(true, placements[0].required);
    }

    @IsTest
    static void savePlacementsPopulatesOpportunityLookup() {
        Account account = new Account(Name = 'Prepare Controller Opportunity Account');
        insert account;
        Opportunity parent = new Opportunity(
            Name = 'Prepare Controller Opportunity',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert parent;
        ContentVersion source = createPdfFile(parent.Id, 'Prepared Opportunity E-Signature File', true);

        PDFESignaturePrepareController.SaveResultDTO result = PDFESignaturePrepareController.savePlacements(
            String.valueOf(parent.Id),
            String.valueOf(source.ContentDocumentId),
            String.valueOf(source.Id),
            '[]'
        );

        ESignature_Envelope__c env = [
            SELECT Parent_Record_Id__c, Parent_Object_Api_Name__c, Account__c, Opportunity__c, Work_Order__c
            FROM ESignature_Envelope__c
            WHERE Id = :result.envelopeId
        ];
        System.assertEquals(String.valueOf(parent.Id), env.Parent_Record_Id__c);
        System.assertEquals('Opportunity', env.Parent_Object_Api_Name__c);
        System.assertEquals(null, env.Account__c);
        System.assertEquals(parent.Id, env.Opportunity__c);
        System.assertEquals(null, env.Work_Order__c);
    }

    private static ContentVersion createPdfFile(Id parentId, String title, Boolean eSignatureFile) {
        ContentVersion source = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n1 0 obj\n<</Type/Page>>\nendobj\n%%EOF'),
            FirstPublishLocationId = parentId,
            E_Signature_File__c = eSignatureFile
        );
        insert source;
        return [
            SELECT Id, ContentDocumentId, E_Signature_File__c
            FROM ContentVersion
            WHERE Id = :source.Id
        ];
    }
}
