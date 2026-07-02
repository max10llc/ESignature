public without sharing class PDFESignatureFinalizerService {
    public static PDF_ESignature_Envelope__c loadEnvelope(Id envelopeId) {
        return [
            SELECT Id, Name, Envelope_Status__c, Parent_Record_Id__c,
                   Signer_Email__c, Final_ContentDocument_Id__c, Final_ContentVersion_Id__c,
                   Completion_Message__c, Error_Message__c, Finalizer_Request_Id__c,
                   Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM PDF_ESignature_Envelope__c
            WHERE Id = :envelopeId
            LIMIT 1
        ];
    }

    public static void markAccepted(Id envelopeId, String requestId, String message) {
        PDF_ESignature_Envelope__c env = loadEnvelope(envelopeId);
        env.Envelope_Status__c = 'Finalizing';
        env.Finalizer_Request_Id__c = requestId;
        env.Error_Message__c = null;
        env.Completion_Message__c = String.isBlank(message)
            ? 'Power Automate accepted the finalization request.'
            : message;
        update env;
        PDFESignatureUtil.audit(env.Id, 'Finalizer Accepted', env.Signer_Email__c, env.Completion_Message__c);
    }

    public static void completeWithBase64(Id envelopeId, String finalPdfBase64, String fileName, String message) {
        if (String.isBlank(finalPdfBase64)) {
            throw new PDFESignatureUtil.AppException('Finalizer callback did not include finalPdfBase64.');
        }
        PDF_ESignature_Envelope__c env = loadEnvelope(envelopeId);
        String resolvedFileName = resolveFileName(env, fileName);

        ContentVersion finalVersion = new ContentVersion();
        finalVersion.Title = titleFromFileName(resolvedFileName);
        finalVersion.PathOnClient = resolvedFileName;
        finalVersion.VersionData = EncodingUtil.base64Decode(finalPdfBase64);
        finalVersion.E_Signature_Status__c = 'Completed';
        Id parentId = PDFESignatureUtil.safeId(env.Parent_Record_Id__c);
        if (parentId != null) {
            finalVersion.FirstPublishLocationId = parentId;
        }
        insert finalVersion;
        finalVersion = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :finalVersion.Id LIMIT 1];
        completeWithFileIds(env, finalVersion.Id, finalVersion.ContentDocumentId, message);
    }

    public static void completeWithExistingFile(Id envelopeId, Id finalContentVersionId, Id finalContentDocumentId, String message) {
        PDF_ESignature_Envelope__c env = loadEnvelope(envelopeId);
        Id contentVersionId = finalContentVersionId;
        Id contentDocumentId = finalContentDocumentId;

        if (contentVersionId != null && contentDocumentId == null) {
            ContentVersion cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :contentVersionId LIMIT 1];
            contentDocumentId = cv.ContentDocumentId;
        }
        if (contentDocumentId != null && contentVersionId == null) {
            List<ContentVersion> versions = [
                SELECT Id
                FROM ContentVersion
                WHERE ContentDocumentId = :contentDocumentId
                AND IsLatest = true
                LIMIT 1
            ];
            if (!versions.isEmpty()) {
                contentVersionId = versions[0].Id;
            }
        }
        if (contentVersionId == null && contentDocumentId == null) {
            throw new PDFESignatureUtil.AppException('Finalizer callback did not include final PDF content or file ids.');
        }
        completeWithFileIds(env, contentVersionId, contentDocumentId, message);
    }

    private static void completeWithFileIds(PDF_ESignature_Envelope__c env, Id finalContentVersionId, Id finalContentDocumentId, String message) {
        env.Envelope_Status__c = 'Signed';
        env.Final_ContentVersion_Id__c = finalContentVersionId;
        env.Final_ContentDocument_Id__c = finalContentDocumentId;
        env.Error_Message__c = null;
        env.Completion_Message__c = String.isBlank(message) ? 'Final signed PDF was created.' : message;
        update env;
        PDFESignatureUtil.updateSourceFileESignatureStatus(env, 'Completed');
        PDFESignatureUtil.updateContentVersionESignatureStatus(finalContentVersionId, 'Completed');
        PDFESignatureUtil.audit(env.Id, 'Finalized', env.Signer_Email__c, env.Completion_Message__c);
    }

    public static void markError(Id envelopeId, String message) {
        PDF_ESignature_Envelope__c env = loadEnvelope(envelopeId);
        env.Envelope_Status__c = 'Error';
        env.Error_Message__c = String.isBlank(message) ? 'Finalizer reported an unknown error.' : message;
        update env;
        PDFESignatureUtil.audit(env.Id, 'Error', env.Signer_Email__c, env.Error_Message__c);
    }

    public static String resolveFileName(PDF_ESignature_Envelope__c env, String fileName) {
        String resolved = String.isBlank(fileName) ? PDFESignatureUtil.getEnvelopeTitle(env) + ' - signed.pdf' : fileName.trim();
        if (!resolved.toLowerCase().endsWith('.pdf')) {
            resolved += '.pdf';
        }
        return resolved;
    }

    public static String titleFromFileName(String fileName) {
        String resolved = String.isBlank(fileName) ? 'Signed Document.pdf' : fileName.trim();
        if (resolved.toLowerCase().endsWith('.pdf')) {
            return resolved.left(resolved.length() - 4);
        }
        return resolved;
    }
}
