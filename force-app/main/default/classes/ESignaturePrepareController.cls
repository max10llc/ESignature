public with sharing class ESignaturePrepareController {
    public class RecordFileDTO {
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String contentVersionId;
        @AuraEnabled public String title;
        @AuraEnabled public String fileExtension;
        @AuraEnabled public Integer contentSize;
        @AuraEnabled public Datetime createdDate;
    }

    public class PdfInfoDTO {
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String contentVersionId;
        @AuraEnabled public String title;
        @AuraEnabled public Integer pageCount;
        @AuraEnabled public String fileExtension;
    }

    public class PlacementDTO {
        @AuraEnabled public String id;
        @AuraEnabled public String fieldType;
        @AuraEnabled public Integer pageNumber;
        @AuraEnabled public Decimal xPercent;
        @AuraEnabled public Decimal yPercent;
        @AuraEnabled public Decimal widthPercent;
        @AuraEnabled public Decimal heightPercent;
        @AuraEnabled public Integer signerNumber;
        @AuraEnabled public Boolean required;
        @AuraEnabled public String label;
        @AuraEnabled public Decimal pdfX;
        @AuraEnabled public Decimal pdfY;
        @AuraEnabled public Decimal pdfWidth;
        @AuraEnabled public Decimal pdfHeight;
    }

    public class SaveResultDTO {
        @AuraEnabled public String envelopeId;
        @AuraEnabled public String message;
    }

    @AuraEnabled(cacheable=true)
    public static List<RecordFileDTO> getRecordPdfFiles(Id recordId) {
        if (recordId == null) {
            return new List<RecordFileDTO>();
        }
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
        ];
        Set<Id> documentIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            documentIds.add(link.ContentDocumentId);
        }
        if (documentIds.isEmpty()) {
            return new List<RecordFileDTO>();
        }
        List<RecordFileDTO> output = new List<RecordFileDTO>();
        for (ContentVersion version : [
            SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize, CreatedDate, ESignature_File__c
            FROM ContentVersion
            WHERE ContentDocumentId IN :documentIds
            AND IsLatest = true
            AND FileExtension = 'pdf'
            AND ESignature_File__c = true
            ORDER BY CreatedDate DESC
        ]) {
            RecordFileDTO row = new RecordFileDTO();
            row.contentDocumentId = version.ContentDocumentId;
            row.contentVersionId = version.Id;
            row.title = version.Title;
            row.fileExtension = version.FileExtension;
            row.contentSize = version.ContentSize;
            row.createdDate = version.CreatedDate;
            output.add(row);
        }
        return output;
    }

    @AuraEnabled(cacheable=true)
    public static PdfInfoDTO getPdfDocumentInfo(String contentDocumentId) {
        if (String.isBlank(contentDocumentId)) {
            throw new AuraHandledException('Content Document Id is required.');
        }
        List<ContentVersion> versions = [
            SELECT Id, ContentDocumentId, Title, FileExtension, VersionData, ESignature_File__c
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId
            AND IsLatest = true
            LIMIT 1
        ];
        if (versions.isEmpty()) {
            throw new AuraHandledException('No latest ContentVersion was found for the selected file.');
        }
        ContentVersion version = versions[0];
        if (String.valueOf(version.FileExtension).toLowerCase() != 'pdf') {
            throw new AuraHandledException('Only PDF files can be prepared for signature.');
        }
        if (version.ESignature_File__c != true) {
            throw new AuraHandledException('This PDF is not marked as an E-Signature File.');
        }
        PdfInfoDTO info = new PdfInfoDTO();
        info.contentDocumentId = version.ContentDocumentId;
        info.contentVersionId = version.Id;
        info.title = version.Title;
        info.fileExtension = version.FileExtension;
        info.pageCount = Integer.valueOf(ESignatureUtil.estimatePageCount(version.VersionData));
        return info;
    }

    @AuraEnabled(cacheable=true)
    public static List<PlacementDTO> getPlacements(String parentRecordId, String contentDocumentId) {
        List<ESignature_Envelope__c> envelopes = [
            SELECT Id
            FROM ESignature_Envelope__c
            WHERE Parent_Record_Id__c = :parentRecordId
            AND (Status__c = 'Draft' OR Status__c = null)
            AND Id IN (
                SELECT Envelope__c
                FROM ESignature_Field__c
                WHERE Content_Document_Id__c = :contentDocumentId
            )
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (envelopes.isEmpty()) {
            return new List<PlacementDTO>();
        }
        List<PlacementDTO> output = new List<PlacementDTO>();
        for (ESignature_Field__c field : [
            SELECT Id, Field_Type__c, Page_Number__c, X_Percent__c, Y_Percent__c,
                   Width_Percent__c, Height_Percent__c, Signer_Number__c, Required__c,
                   Label__c, Pdf_X__c, Pdf_Y__c, Pdf_Width__c, Pdf_Height__c
            FROM ESignature_Field__c
            WHERE Envelope__c = :envelopes[0].Id
            ORDER BY Page_Number__c ASC, Sequence__c ASC, CreatedDate ASC
        ]) {
            PlacementDTO row = new PlacementDTO();
            row.id = field.Id;
            row.fieldType = field.Field_Type__c;
            row.pageNumber = field.Page_Number__c == null ? 1 : Integer.valueOf(field.Page_Number__c);
            row.xPercent = field.X_Percent__c;
            row.yPercent = field.Y_Percent__c;
            row.widthPercent = field.Width_Percent__c;
            row.heightPercent = field.Height_Percent__c;
            row.signerNumber = field.Signer_Number__c == null ? 1 : Integer.valueOf(field.Signer_Number__c);
            row.required = field.Required__c;
            row.label = field.Label__c;
            row.pdfX = field.Pdf_X__c;
            row.pdfY = field.Pdf_Y__c;
            row.pdfWidth = field.Pdf_Width__c;
            row.pdfHeight = field.Pdf_Height__c;
            output.add(row);
        }
        return output;
    }

    @AuraEnabled
    public static SaveResultDTO savePlacements(String parentRecordId, String contentDocumentId, String contentVersionId, String placementsJson) {
        if (String.isBlank(parentRecordId)) {
            throw new AuraHandledException('Parent Record Id is required.');
        }
        if (String.isBlank(contentDocumentId)) {
            throw new AuraHandledException('Content Document Id is required.');
        }
        ContentVersion version = [
            SELECT Id, ContentDocumentId, Title, FileExtension, VersionData, ESignature_File__c
            FROM ContentVersion
            WHERE Id = :contentVersionId
            LIMIT 1
        ];
        Id requestedDocumentId = ESignatureUtil.safeId(contentDocumentId);
        if (requestedDocumentId == null || version.ContentDocumentId != requestedDocumentId) {
            throw new AuraHandledException('Selected ContentVersion does not belong to the selected ContentDocument.');
        }
        if (String.valueOf(version.FileExtension).toLowerCase() != 'pdf') {
            throw new AuraHandledException('Only PDF files can be prepared for signature.');
        }
        if (version.ESignature_File__c != true) {
            throw new AuraHandledException('This PDF is not marked as an E-Signature File.');
        }
        Integer pageCount = Integer.valueOf(ESignatureUtil.estimatePageCount(version.VersionData));
        List<ESignature_Envelope__c> envelopes = [
            SELECT Id, Status__c
            FROM ESignature_Envelope__c
            WHERE Parent_Record_Id__c = :parentRecordId
            AND (Status__c = 'Draft' OR Status__c = null)
            AND Id IN (
                SELECT Envelope__c
                FROM ESignature_Field__c
                WHERE Content_Document_Id__c = :contentDocumentId
            )
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        List<Object> rows = String.isBlank(placementsJson)
            ? new List<Object>()
            : (List<Object>) JSON.deserializeUntyped(placementsJson);
        if (rows.isEmpty()) {
            throw new AuraHandledException('There are no fields to save.');
        }

        ESignature_Envelope__c envelope;
        Boolean created = false;
        if (envelopes.isEmpty()) {
            envelope = new ESignature_Envelope__c();
            envelope.Status__c = 'Draft';
            envelope.Sender_User__c = UserInfo.getUserId();
            created = true;
        } else {
            envelope = envelopes[0];
        }
        ESignatureUtil.stampEnvelopeParent(envelope, parentRecordId);
        envelope.Page_Count__c = pageCount;
        envelope.Source_ContentVersion_Id__c = String.valueOf(version.Id);
        envelope.Source_ContentDocument_Id__c = String.valueOf(version.ContentDocumentId);
        envelope.Source_File_Title__c = version.Title;
        upsert envelope;
        cancelPriorOpenEnvelopes(envelope);

        delete [SELECT Id FROM ESignature_Field__c WHERE Envelope__c = :envelope.Id];

        List<ESignature_Field__c> fieldsToInsert = new List<ESignature_Field__c>();
        Integer sequence = 1;
        for (Object item : rows) {
            Map<String, Object> row = (Map<String, Object>) item;
            ESignature_Field__c field = new ESignature_Field__c();
            field.Envelope__c = envelope.Id;
            field.Parent_Record_Id__c = parentRecordId;
            field.Content_Document_Id__c = contentDocumentId;
            field.Content_Version_Id__c = version.Id;
            field.Field_Type__c = ESignatureUtil.stringValue(row.get('fieldType'));
            field.Page_Number__c = ESignatureUtil.intValue(row.get('pageNumber'), 1);
            field.X_Percent__c = ESignatureUtil.decimalValue(row.get('xPercent'), 0);
            field.Y_Percent__c = ESignatureUtil.decimalValue(row.get('yPercent'), 0);
            field.Width_Percent__c = ESignatureUtil.decimalValue(row.get('widthPercent'), 0.2);
            field.Height_Percent__c = ESignatureUtil.decimalValue(row.get('heightPercent'), 0.04);
            field.Signer_Number__c = ESignatureUtil.intValue(row.get('signerNumber'), 1);
            field.Required__c = ESignatureUtil.boolValue(row.get('required'), true);
            field.Label__c = ESignatureUtil.stringValue(row.get('label'));
            field.Pdf_X__c = ESignatureUtil.decimalValue(row.get('pdfX'), field.X_Percent__c * 612);
            field.Pdf_Y__c = ESignatureUtil.decimalValue(row.get('pdfY'), 792 - ((field.Y_Percent__c + field.Height_Percent__c) * 792));
            field.Pdf_Width__c = ESignatureUtil.decimalValue(row.get('pdfWidth'), field.Width_Percent__c * 612);
            field.Pdf_Height__c = ESignatureUtil.decimalValue(row.get('pdfHeight'), field.Height_Percent__c * 792);
            field.Page_Width_Points__c = 612;
            field.Page_Height_Points__c = 792;
            field.Sequence__c = sequence;
            fieldsToInsert.add(field);
            sequence++;
        }
        if (!fieldsToInsert.isEmpty()) {
            insert fieldsToInsert;
        }
        ESignatureUtil.audit(envelope.Id, created ? 'Draft Created' : 'Fields Saved', UserInfo.getUserEmail(), 'Saved ' + fieldsToInsert.size() + ' prepared fields.');

        SaveResultDTO result = new SaveResultDTO();
        result.envelopeId = envelope.Id;
        ESignature_Envelope__c savedEnvelope = [
            SELECT Name
            FROM ESignature_Envelope__c
            WHERE Id = :envelope.Id
            LIMIT 1
        ];
        String envelopeLabel = String.isBlank(savedEnvelope.Name) ? String.valueOf(envelope.Id) : savedEnvelope.Name;
        result.message = 'Saved ' + fieldsToInsert.size() + ' field placement' + (fieldsToInsert.size() == 1 ? '' : 's') + ' to draft envelope ' + envelopeLabel + '.';
        return result;
    }

    private static void cancelPriorOpenEnvelopes(ESignature_Envelope__c currentEnv) {
        if (currentEnv == null || currentEnv.Id == null || String.isBlank(currentEnv.Parent_Record_Id__c)) {
            return;
        }
        List<ESignature_Envelope__c> priorOpenEnvelopes = [
            SELECT Id, Status__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM ESignature_Envelope__c
            WHERE Parent_Record_Id__c = :currentEnv.Parent_Record_Id__c
            AND Id != :currentEnv.Id
            AND (Status__c = null OR Status__c IN ('Draft', 'Sent', 'Viewed'))
            FOR UPDATE
        ];
        if (priorOpenEnvelopes.isEmpty()) {
            return;
        }

        for (ESignature_Envelope__c prior : priorOpenEnvelopes) {
            prior.Status__c = 'Canceled';
        }
        update priorOpenEnvelopes;

        String details = 'Envelope canceled because a newer e-signature draft was saved for this record.';
        for (ESignature_Envelope__c prior : priorOpenEnvelopes) {
            ESignatureUtil.updateSourceFileESignatureStatus(prior, 'Canceled');
            ESignatureUtil.audit(prior.Id, 'Canceled', UserInfo.getUserEmail(), details);
        }
    }
}
