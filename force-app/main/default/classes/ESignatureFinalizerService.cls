public without sharing class ESignatureFinalizerService {
    public static ESignature_Envelope__c loadEnvelope(Id envelopeId) {
        return [
            SELECT Id, Name, Status__c, Parent_Record_Id__c, Parent_Object_Api_Name__c,
                   Signer_Name__c, Signer_Email__c, Sender_User__c,
                   Final_ContentDocument_Id__c, Final_ContentVersion_Id__c,
                   Completion_Message__c, Error_Message__c, Finalizer_Request_Id__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM ESignature_Envelope__c
            WHERE Id = :envelopeId
            LIMIT 1
        ];
    }

    public static void markAccepted(Id envelopeId, String requestId, String message) {
        ESignature_Envelope__c env = loadEnvelope(envelopeId);
        env.Status__c = 'Finalizing';
        env.Finalizer_Request_Id__c = requestId;
        env.Error_Message__c = null;
        env.Completion_Message__c = String.isBlank(message)
            ? 'Power Automate accepted the finalization request.'
            : message;
        update env;
        ESignatureUtil.audit(env.Id, 'Finalizer Accepted', env.Signer_Email__c, env.Completion_Message__c);
    }

    public static void completeWithBase64(Id envelopeId, String finalPdfBase64, String fileName, String message) {
        if (String.isBlank(finalPdfBase64)) {
            throw new ESignatureUtil.AppException('Finalizer callback did not include finalPdfBase64.');
        }
        ESignature_Envelope__c env = loadEnvelope(envelopeId);
        String resolvedFileName = resolveFileName(env, fileName);

        ContentVersion finalVersion = new ContentVersion();
        finalVersion.Title = titleFromFileName(resolvedFileName);
        finalVersion.PathOnClient = resolvedFileName;
        finalVersion.VersionData = EncodingUtil.base64Decode(finalPdfBase64);
        finalVersion.ESignature_Status__c = 'Completed';
        Id parentId = ESignatureUtil.safeId(env.Parent_Record_Id__c);
        if (parentId != null) {
            finalVersion.FirstPublishLocationId = parentId;
        }
        insert finalVersion;
        finalVersion = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :finalVersion.Id LIMIT 1];
        completeWithFileIds(env, finalVersion.Id, finalVersion.ContentDocumentId, message);
    }

    public static void completeWithExistingFile(Id envelopeId, Id finalContentVersionId, Id finalContentDocumentId, String message) {
        ESignature_Envelope__c env = loadEnvelope(envelopeId);
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
            throw new ESignatureUtil.AppException('Finalizer callback did not include final PDF content or file ids.');
        }
        completeWithFileIds(env, contentVersionId, contentDocumentId, message);
    }

    private static void completeWithFileIds(ESignature_Envelope__c env, Id finalContentVersionId, Id finalContentDocumentId, String message) {
        env.Status__c = 'Signed';
        env.Final_ContentVersion_Id__c = finalContentVersionId;
        env.Final_ContentDocument_Id__c = finalContentDocumentId;
        env.Error_Message__c = null;
        env.Completion_Message__c = String.isBlank(message) ? 'Final signed PDF was created.' : message;
        update env;
        ESignatureUtil.updateSourceFileESignatureStatus(env, 'Completed');
        ESignatureUtil.updateContentVersionESignatureStatus(finalContentVersionId, 'Completed');
        ESignatureUtil.audit(env.Id, 'Finalized', env.Signer_Email__c, env.Completion_Message__c);
        sendCompletionNotificationEmail(env);
    }

    public static void markError(Id envelopeId, String message) {
        ESignature_Envelope__c env = loadEnvelope(envelopeId);
        env.Status__c = 'Error';
        env.Error_Message__c = String.isBlank(message) ? 'Finalizer reported an unknown error.' : message;
        update env;
        ESignatureUtil.audit(env.Id, 'Error', env.Signer_Email__c, env.Error_Message__c);
    }

    public static String resolveFileName(ESignature_Envelope__c env, String fileName) {
        String resolved = String.isBlank(fileName) ? ESignatureUtil.getEnvelopeTitle(env) + ' - signed.pdf' : fileName.trim();
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

    private static void sendCompletionNotificationEmail(ESignature_Envelope__c env) {
        try {
            List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
            List<Messaging.EmailFileAttachment> attachments = completionEmailAttachments(env);
            addCompletionEmailMessage(
                messages,
                env == null ? null : env.Signer_Email__c,
                buildSignerCompletionEmailContent(env),
                attachments
            );
            addCompletionEmailMessage(
                messages,
                ESignatureUtil.senderEmail(env == null ? null : env.Sender_User__c),
                buildSalesforceUserCompletionEmailContent(env),
                attachments
            );
            if (messages.isEmpty()) {
                return;
            }
            Messaging.sendEmail(messages);
        } catch (Exception ignore) {}
    }

    private static void addCompletionEmailMessage(
        List<Messaging.SingleEmailMessage> messages,
        String recipientEmail,
        ESignatureUtil.EmailContent content,
        List<Messaging.EmailFileAttachment> attachments
    ) {
        if (content == null) {
            return;
        }
        addCompletionEmailMessage(messages, recipientEmail, content.subject, content.htmlBody, attachments);
    }

    private static void addCompletionEmailMessage(
        List<Messaging.SingleEmailMessage> messages,
        String recipientEmail,
        String subject,
        String htmlBody,
        List<Messaging.EmailFileAttachment> attachments
    ) {
        if (messages == null || !isValidEmail(recipientEmail)) {
            return;
        }
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ recipientEmail.trim() });
        message.setSubject(subject);
        message.setHtmlBody(htmlBody);
        if (attachments != null && !attachments.isEmpty()) {
            message.setFileAttachments(attachments);
        }
        message.setSaveAsActivity(false);
        ESignatureUtil.applyConfiguredOrgWideEmailAddress(message);
        messages.add(message);
    }

    @TestVisible
    private static List<Messaging.EmailFileAttachment> completionEmailAttachments(ESignature_Envelope__c env) {
        List<Messaging.EmailFileAttachment> attachments = new List<Messaging.EmailFileAttachment>();
        ContentVersion finalVersion = loadFinalContentVersion(env);
        if (finalVersion == null || finalVersion.VersionData == null) {
            return attachments;
        }

        Messaging.EmailFileAttachment attachment = new Messaging.EmailFileAttachment();
        attachment.setFileName(finalPdfFileName(finalVersion));
        attachment.setBody(finalVersion.VersionData);
        attachment.setContentType('application/pdf');
        attachments.add(attachment);
        return attachments;
    }

    private static ContentVersion loadFinalContentVersion(ESignature_Envelope__c env) {
        if (env == null) {
            return null;
        }

        Id versionId = ESignatureUtil.safeId(env.Final_ContentVersion_Id__c);
        if (versionId != null) {
            List<ContentVersion> versions = [
                SELECT Id, Title, FileExtension, PathOnClient, VersionData
                FROM ContentVersion
                WHERE Id = :versionId
                LIMIT 1
            ];
            if (!versions.isEmpty()) {
                return versions[0];
            }
        }

        Id documentId = ESignatureUtil.safeId(env.Final_ContentDocument_Id__c);
        if (documentId == null) {
            return null;
        }
        List<ContentVersion> latestVersions = [
            SELECT Id, Title, FileExtension, PathOnClient, VersionData
            FROM ContentVersion
            WHERE ContentDocumentId = :documentId
            AND IsLatest = true
            LIMIT 1
        ];
        return latestVersions.isEmpty() ? null : latestVersions[0];
    }

    private static String finalPdfFileName(ContentVersion version) {
        String fileName = version == null ? null : version.PathOnClient;
        if (String.isBlank(fileName)) {
            fileName = version == null ? null : version.Title;
            if (String.isBlank(fileName)) {
                fileName = 'Signed Document';
            }
            if (version != null && !String.isBlank(version.FileExtension) && !fileName.toLowerCase().endsWith('.' + version.FileExtension.toLowerCase())) {
                fileName += '.' + version.FileExtension;
            }
        }
        if (String.isBlank(fileName)) {
            fileName = 'Signed Document.pdf';
        }
        if (!fileName.toLowerCase().endsWith('.pdf')) {
            fileName += '.pdf';
        }
        return fileName;
    }

    @TestVisible
    private static String buildSignerCompletionEmailHtml(ESignature_Envelope__c env) {
        return buildSignerCompletionEmailContent(env).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildSignerCompletionEmailContent(ESignature_Envelope__c env) {
        String signerName = env == null || String.isBlank(env.Signer_Name__c) ? 'there' : env.Signer_Name__c;
        String safeSignerName = ESignatureUtil.escapeHtml(signerName);
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        String safeDocumentTitle = ESignatureUtil.escapeHtml(documentTitle);
        String message = completionMessage(env);

        String fallbackSubject = 'Signature request completed: ' + documentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow('Hi ' + safeSignerName + ',')
            + ESignatureUtil.emailParagraphRow('The signature process is complete.')
            + ESignatureUtil.emailDocumentBlockRow('Document', safeDocumentTitle, '#0176d3')
            + ESignatureUtil.emailParagraphRow('<strong>Status:</strong> Completed')
            + ESignatureUtil.emailParagraphRow(ESignatureUtil.escapeHtml(message))
            + ESignatureUtil.emailSubtleRow('The completed signed PDF has been returned to the sender in Salesforce.')
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Completed_Signer',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'SignerName' => signerName,
                'DocumentTitle' => documentTitle,
                'CompletionMessage' => message
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'SignerName' => safeSignerName,
                'DocumentTitle' => safeDocumentTitle,
                'CompletionMessage' => ESignatureUtil.escapeHtml(message)
            }
        );
    }

    @TestVisible
    private static String buildSalesforceUserCompletionEmailHtml(ESignature_Envelope__c env) {
        return buildSalesforceUserCompletionEmailContent(env).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildSalesforceUserCompletionEmailContent(ESignature_Envelope__c env) {
        String signerName = env == null || String.isBlank(env.Signer_Name__c) ? 'The signer' : env.Signer_Name__c;
        String signerEmail = env == null ? null : env.Signer_Email__c;
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        String safeDocumentTitle = ESignatureUtil.escapeHtml(documentTitle);
        String message = completionMessage(env);
        String signer = ESignatureUtil.escapeHtml(signerName)
            + (String.isBlank(signerEmail) ? '' : ' (' + ESignatureUtil.escapeHtml(signerEmail) + ')');
        String signerText = signerName + (String.isBlank(signerEmail) ? '' : ' (' + signerEmail + ')');
        String recordId = env == null ? '' : env.Parent_Record_Id__c;
        String recordObject = env == null ? '' : env.Parent_Object_Api_Name__c;
        String recordName = ESignatureUtil.parentRecordName(recordId, recordObject);
        String recordUrl = recordUrl(recordId, recordObject);
        String safeRecordId = ESignatureUtil.escapeHtml(recordId);
        String safeRecordName = ESignatureUtil.escapeHtml(recordName);
        String safeRecordUrl = ESignatureUtil.escapeHtml(recordUrl);
        String safeRecordLabel = String.isBlank(safeRecordName) ? safeRecordId : safeRecordName;
        String recordRow = String.isBlank(recordId)
            ? ''
            : ESignatureUtil.emailParagraphRow('<strong>Record:</strong> <a href="' + safeRecordUrl + '" style="color:#0176d3;text-decoration:underline;word-break:break-all;">' + safeRecordLabel + '</a>');

        String fallbackSubject = 'Signature request completed: ' + documentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow('The signature request has been completed.')
            + ESignatureUtil.emailDocumentBlockRow('Document', safeDocumentTitle, '#0176d3')
            + ESignatureUtil.emailParagraphRow('<strong>Signer:</strong> ' + signer)
            + ESignatureUtil.emailParagraphRow('<strong>Status:</strong> Completed')
            + recordRow
            + ESignatureUtil.emailParagraphRow(ESignatureUtil.escapeHtml(message))
            + ESignatureUtil.emailSubtleRow('The completed signed PDF has been attached in Salesforce.')
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Completed_Salesforce_User',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'SignerName' => signerName,
                'SignerEmail' => signerEmail,
                'Signer' => signerText,
                'DocumentTitle' => documentTitle,
                'CompletionMessage' => message,
                'RecordId' => recordId,
                'RecordName' => recordName,
                'Record' => recordUrl,
                'RecordUrl' => recordUrl,
                'RecordObject' => recordObject
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'SignerName' => ESignatureUtil.escapeHtml(signerName),
                'SignerEmail' => ESignatureUtil.escapeHtml(signerEmail),
                'Signer' => signer,
                'DocumentTitle' => safeDocumentTitle,
                'CompletionMessage' => ESignatureUtil.escapeHtml(message),
                'RecordId' => safeRecordId,
                'RecordName' => safeRecordName,
                'Record' => safeRecordUrl,
                'RecordUrl' => safeRecordUrl,
                'RecordObject' => ESignatureUtil.escapeHtml(recordObject)
            }
        );
    }

    private static String recordUrl(String recordId, String recordObject) {
        if (String.isBlank(recordId)) {
            return '';
        }
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        String root = baseUrl.endsWith('/') ? baseUrl.left(baseUrl.length() - 1) : baseUrl;
        if (String.isBlank(recordObject)) {
            return root + '/' + recordId;
        }
        return root + '/lightning/r/' + EncodingUtil.urlEncode(recordObject.trim(), 'UTF-8') + '/' + recordId.trim() + '/view';
    }

    private static String completionMessage(ESignature_Envelope__c env) {
        String message = env == null ? null : env.Completion_Message__c;
        return String.isBlank(message) ? 'The final signed PDF was created.' : message;
    }

    private static Boolean isValidEmail(String value) {
        if (String.isBlank(value)) {
            return false;
        }
        String normalized = value.trim();
        Integer atIndex = normalized.indexOf('@');
        Integer dotIndex = normalized.lastIndexOf('.');
        return normalized.indexOf(' ') < 0 &&
            atIndex > 0 &&
            dotIndex > atIndex + 1 &&
            dotIndex < normalized.length() - 1;
    }

    @TestVisible
    private static String buildCompletionNotificationEmailHtml(ESignature_Envelope__c env) {
        return buildSalesforceUserCompletionEmailHtml(env);
    }
}
