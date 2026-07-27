@IsTest
private class ESignaturePrepareControllerTest {
    @IsTest
    static void getRecordPdfFilesReturnsOnlyMarkedPdfFiles() {
        Account parent = new Account(Name = 'Prepare Controller Parent');
        insert parent;
        ContentVersion eligible = createPdfFile(parent.Id, 'Eligible E-Signature File', true);
        createPdfFile(parent.Id, 'Regular PDF File', false);

        List<ESignaturePrepareController.RecordFileDTO> files =
            ESignaturePrepareController.getRecordPdfFiles(parent.Id);

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
            ESignaturePrepareController.getPdfDocumentInfo(String.valueOf(source.ContentDocumentId));
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

        ESignaturePrepareController.PdfInfoDTO info =
            ESignaturePrepareController.getPdfDocumentInfo(String.valueOf(source.ContentDocumentId));

        System.assertEquals(String.valueOf(source.ContentDocumentId), info.contentDocumentId);
        System.assertEquals(String.valueOf(source.Id), info.contentVersionId);
        System.assertEquals('Marked PDF File', info.title);
        System.assertEquals('pdf', info.fileExtension);
        System.assertEquals(1, info.pageCount);
    }

    @IsTest
    static void getFieldAvailabilityReflectsDefaultMetadata() {
        ESignature_Setting__mdt settings = ESignatureUtil.getSettings();

        ESignaturePrepareController.FieldAvailabilityDTO availability =
            ESignaturePrepareController.getFieldAvailability();

        System.assertEquals(settings.Enable_Checkbox_Field__c != false, availability.checkboxFieldEnabled);
        System.assertEquals(settings.Enable_Text_Field__c != false, availability.textFieldEnabled);
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

        ESignaturePrepareController.SaveResultDTO result = ESignaturePrepareController.savePlacements(
            String.valueOf(parent.Id),
            String.valueOf(source.ContentDocumentId),
            String.valueOf(source.Id),
            placementsJson
        );

        System.assertNotEquals(null, result.envelopeId, 'Saving placements should create or update a draft envelope.');
        ESignature_Envelope__c env = [
            SELECT Status__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c, Source_File_Title__c,
                   Parent_Record_Id__c, Parent_Object_Api_Name__c, Account__c, Opportunity__c, Work_Order__c
            FROM ESignature_Envelope__c
            WHERE Id = :result.envelopeId
        ];
        System.assertEquals('Draft', env.Status__c);
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
        System.assert(result.message.contains('Saved 1 field placement to draft envelope '), 'Success message should identify the saved field count and envelope.');
        System.assert(!result.message.endsWith(' null.'), 'Success message should not render a null envelope name.');

        List<ESignaturePrepareController.PlacementDTO> placements =
            ESignaturePrepareController.getPlacements(String.valueOf(parent.Id), String.valueOf(source.ContentDocumentId));
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

        ESignaturePrepareController.SaveResultDTO result = ESignaturePrepareController.savePlacements(
            String.valueOf(parent.Id),
            String.valueOf(source.ContentDocumentId),
            String.valueOf(source.Id),
            placementJson()
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

    @IsTest
    static void savePlacementsCancelsPriorOpenEnvelopesForSameParent() {
        Account parent = new Account(Name = 'Prepare Controller Cancellation Parent');
        insert parent;
        ContentVersion newSource = createPdfFile(parent.Id, 'Current Prepared E-Signature File', true);
        ContentVersion draftSource = createPdfFile(parent.Id, 'Prior Draft E-Signature File', true);
        ContentVersion sentSource = createPdfFile(parent.Id, 'Prior Sent E-Signature File', true);
        ContentVersion viewedSource = createPdfFile(parent.Id, 'Prior Viewed E-Signature File', true);
        ContentVersion blankSource = createPdfFile(parent.Id, 'Prior Blank E-Signature File', true);
        ContentVersion signedSource = createPdfFile(parent.Id, 'Prior Signed E-Signature File', true);

        Account otherParent = new Account(Name = 'Prepare Controller Other Parent');
        insert otherParent;
        ContentVersion otherSource = createPdfFile(otherParent.Id, 'Other Parent E-Signature File', true);

        ESignature_Envelope__c priorDraft = envelope(parent.Id, 'Draft', draftSource);
        ESignature_Envelope__c priorSent = envelope(parent.Id, 'Sent', sentSource);
        ESignature_Envelope__c priorViewed = envelope(parent.Id, 'Viewed', viewedSource);
        priorViewed.Parent_Record_Id__c = String.valueOf(parent.Id).substring(0, 15);
        ESignature_Envelope__c priorBlank = envelope(parent.Id, null, blankSource);
        ESignature_Envelope__c priorSigned = envelope(parent.Id, 'Signed', signedSource);
        ESignature_Envelope__c otherSent = envelope(otherParent.Id, 'Sent', otherSource);
        insert new List<ESignature_Envelope__c>{ priorDraft, priorSent, priorViewed, priorBlank, priorSigned, otherSent };

        ESignaturePrepareController.SaveResultDTO result = ESignaturePrepareController.savePlacements(
            String.valueOf(parent.Id),
            String.valueOf(newSource.ContentDocumentId),
            String.valueOf(newSource.Id),
            placementJson()
        );

        Map<Id, ESignature_Envelope__c> envelopes = new Map<Id, ESignature_Envelope__c>([
            SELECT Status__c, Cancellation_Reason__c
            FROM ESignature_Envelope__c
            WHERE Id IN :new Set<Id>{ ESignatureUtil.safeId(result.envelopeId), priorDraft.Id, priorSent.Id, priorViewed.Id, priorBlank.Id, priorSigned.Id, otherSent.Id }
        ]);
        System.assertEquals('Draft', envelopes.get(ESignatureUtil.safeId(result.envelopeId)).Status__c, 'The current draft should stay active.');
        System.assertEquals('Canceled', envelopes.get(priorDraft.Id).Status__c, 'Prior draft envelope should be canceled.');
        System.assertEquals('Canceled', envelopes.get(priorSent.Id).Status__c, 'Prior sent envelope should be canceled.');
        System.assertEquals('Canceled', envelopes.get(priorViewed.Id).Status__c, 'Prior viewed envelope should be canceled.');
        System.assertEquals('Canceled', envelopes.get(priorBlank.Id).Status__c, 'Prior blank-status envelope should be canceled.');
        System.assertEquals('Signed', envelopes.get(priorSigned.Id).Status__c, 'Completed envelopes should not be changed.');
        System.assertEquals('Sent', envelopes.get(otherSent.Id).Status__c, 'Other parent envelopes should not be changed.');
        System.assertEquals('Envelope canceled because a newer e-signature draft was saved for this record.', envelopes.get(priorDraft.Id).Cancellation_Reason__c);
        System.assertEquals('Envelope canceled because a newer e-signature draft was saved for this record.', envelopes.get(priorSent.Id).Cancellation_Reason__c);
        System.assertEquals('Envelope canceled because a newer e-signature draft was saved for this record.', envelopes.get(priorViewed.Id).Cancellation_Reason__c);
        System.assertEquals('Envelope canceled because a newer e-signature draft was saved for this record.', envelopes.get(priorBlank.Id).Cancellation_Reason__c);

        System.assertEquals(4, [
            SELECT COUNT()
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c IN :new Set<Id>{ priorDraft.Id, priorSent.Id, priorViewed.Id, priorBlank.Id }
            AND Event_Type__c = 'Canceled'
        ], 'Each automatically canceled envelope should receive a cancel audit event.');
    }

    @IsTest
    static void savePlacementsRejectsEmptyPlacementList() {
        Account parent = new Account(Name = 'Prepare Controller Empty Save Parent');
        insert parent;
        ContentVersion source = createPdfFile(parent.Id, 'Empty Save E-Signature File', true);

        try {
            ESignaturePrepareController.savePlacements(
                String.valueOf(parent.Id),
                String.valueOf(source.ContentDocumentId),
                String.valueOf(source.Id),
                '[]'
            );
            System.assert(false, 'Expected empty placement saves to be rejected.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage(), 'The caller should receive a clear no-fields error.');
        }

        String parentId = String.valueOf(parent.Id);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM ESignature_Envelope__c
            WHERE Parent_Record_Id__c = :parentId
        ], 'Empty saves should not create draft envelopes.');
    }

    private static String placementJson() {
        return JSON.serialize(new List<Object>{
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
    }

    private static ContentVersion createPdfFile(Id parentId, String title, Boolean eSignatureFile) {
        ContentVersion source = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n1 0 obj\n<</Type/Page>>\nendobj\n%%EOF'),
            FirstPublishLocationId = parentId,
            ESignature_File__c = eSignatureFile
        );
        insert source;
        return [
            SELECT Id, ContentDocumentId, ESignature_File__c
            FROM ContentVersion
            WHERE Id = :source.Id
        ];
    }

    private static ESignature_Envelope__c envelope(Id parentId, String status, ContentVersion source) {
        return new ESignature_Envelope__c(
            Status__c = status,
            Parent_Record_Id__c = String.valueOf(parentId),
            Parent_Object_Api_Name__c = 'Account',
            Source_ContentVersion_Id__c = String.valueOf(source.Id),
            Source_ContentDocument_Id__c = String.valueOf(source.ContentDocumentId)
        );
    }
}
