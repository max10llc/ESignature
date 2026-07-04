public with sharing class ESignatureSendController {
    public class EnvelopeDTO {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String status;
        @AuraEnabled public Integer fieldCount;
        @AuraEnabled public Datetime lastModifiedDate;
    }

    public class SendResultDTO {
        @AuraEnabled public String envelopeId;
        @AuraEnabled public String signingUrl;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
    }

    @AuraEnabled(cacheable=true)
    public static List<EnvelopeDTO> getDraftEnvelopes(String parentRecordId, String refreshKey) {
        List<EnvelopeDTO> output = new List<EnvelopeDTO>();
        List<ESignature_Envelope__c> envelopes = [
            SELECT Id, Name, Envelope_Status__c, LastModifiedDate,
                   (SELECT Id FROM ESignature_Fields__r)
            FROM ESignature_Envelope__c
            WHERE Parent_Record_Id__c = :parentRecordId
            AND (Envelope_Status__c = 'Draft' OR Envelope_Status__c = null)
            ORDER BY LastModifiedDate DESC
            LIMIT 50
        ];
        Set<Id> envelopeIds = new Set<Id>();
        for (ESignature_Envelope__c env : envelopes) {
            envelopeIds.add(env.Id);
        }
        Map<Id, Id> documentIdByEnvelopeId = ESignatureUtil.getSourceDocumentIdsByEnvelopeId(envelopeIds);
        Set<Id> documentIds = new Set<Id>();
        for (Id documentId : documentIdByEnvelopeId.values()) {
            if (documentId != null) {
                documentIds.add(documentId);
            }
        }
        Map<Id, String> titleByDocumentId = ESignatureUtil.getContentDocumentTitles(documentIds);
        for (ESignature_Envelope__c env : envelopes) {
            EnvelopeDTO row = new EnvelopeDTO();
            row.id = env.Id;
            row.name = env.Name;
            row.title = ESignatureUtil.titleFromEnvelope(env, titleByDocumentId, documentIdByEnvelopeId);
            row.status = String.isBlank(env.Envelope_Status__c) ? 'Draft' : env.Envelope_Status__c;
            row.lastModifiedDate = env.LastModifiedDate;
            row.fieldCount = env.ESignature_Fields__r == null ? 0 : env.ESignature_Fields__r.size();
            output.add(row);
        }
        return output;
    }

    @AuraEnabled
    public static SendResultDTO sendEnvelope(String envelopeId, String signerName, String signerEmail, String signerTitle, Integer expirationDays) {
        if (String.isBlank(envelopeId)) {
            throw new AuraHandledException('Select a draft envelope to send.');
        }
        if (String.isBlank(signerName)) {
            throw new AuraHandledException('Signer name is required.');
        }
        if (String.isBlank(signerEmail)) {
            throw new AuraHandledException('Signer email is required.');
        }
        ESignature_Envelope__c env = [
            SELECT Id, Name, Envelope_Status__c, Parent_Record_Id__c, Parent_Object_Api_Name__c, Secure_Token_Hash__c,
                   Signer_Name__c, Signer_Email__c, Signer_Title__c, Sent_At__c,
                   Expires_At__c, Public_Signing_URL__c, Sender_User__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM ESignature_Envelope__c
            WHERE Id = :envelopeId
            LIMIT 1
        ];
        if (!String.isBlank(env.Envelope_Status__c) && env.Envelope_Status__c != 'Draft') {
            throw new AuraHandledException('Only draft envelopes can be sent. Current status: ' + env.Envelope_Status__c);
        }
        Integer fieldCount = [SELECT COUNT() FROM ESignature_Field__c WHERE Envelope__c = :env.Id];
        if (fieldCount == 0) {
            throw new AuraHandledException('Add at least one field before sending the envelope.');
        }
        ESignature_Setting__mdt settings = ESignatureUtil.getSettings();
        Integer days = expirationDays == null || expirationDays <= 0
            ? (settings.Default_Expiration_Days__c == null ? 365 : Integer.valueOf(settings.Default_Expiration_Days__c))
            : expirationDays;
        if (days > 365) {
            days = 365;
        }
        String token = ESignatureUtil.generateToken();
        String signingUrl = ESignatureUtil.buildSigningUrl(token);
        env.Secure_Token_Hash__c = ESignatureUtil.hashToken(token);
        env.Signer_Name__c = signerName.trim();
        env.Signer_Email__c = signerEmail.trim();
        env.Signer_Title__c = String.isBlank(signerTitle) ? null : signerTitle.trim();
        env.Envelope_Status__c = 'Sent';
        env.Sent_At__c = System.now();
        env.Expires_At__c = System.now().addDays(days);
        env.Public_Signing_URL__c = signingUrl;
        env.Sender_User__c = UserInfo.getUserId();
        ESignatureUtil.stampEnvelopeParent(env, env.Parent_Record_Id__c);
        stampSourceFields(env);
        update env;

        try {
            ESignatureUtil.cacheSourcePdfForEnvelope(env.Id);
        } catch (Exception ex) {
            env.Envelope_Status__c = 'Error';
            env.Error_Message__c = 'Unable to cache source PDF for public signing: ' + ex.getMessage();
            update env;
            throw new AuraHandledException('Unable to cache source PDF for public signing: ' + ex.getMessage());
        }

        cancelPriorOpenEnvelopes(env);
        sendEmail(env, signingUrl);
        ESignatureUtil.updateSourceFileESignatureStatus(env, 'Sent');
        ESignatureUtil.audit(env.Id, 'Sent', UserInfo.getUserEmail(), 'Envelope sent to ' + env.Signer_Email__c + '.');

        SendResultDTO result = new SendResultDTO();
        result.envelopeId = env.Id;
        result.signingUrl = signingUrl;
        result.status = env.Envelope_Status__c;
        result.message = 'Envelope sent to ' + env.Signer_Email__c + '.';
        return result;
    }

    private static void stampSourceFields(ESignature_Envelope__c env) {
        ContentVersion source = ESignatureUtil.getLatestSourceVersion(env, false);
        if (source == null) {
            return;
        }
        env.Source_ContentVersion_Id__c = String.valueOf(source.Id);
        env.Source_ContentDocument_Id__c = String.valueOf(source.ContentDocumentId);
        env.Source_File_Title__c = source.Title;
    }

    private static void cancelPriorOpenEnvelopes(ESignature_Envelope__c currentEnv) {
        if (currentEnv == null || currentEnv.Id == null || String.isBlank(currentEnv.Parent_Record_Id__c)) {
            return;
        }
        List<ESignature_Envelope__c> priorOpenEnvelopes = [
            SELECT Id, Envelope_Status__c, Signer_Email__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM ESignature_Envelope__c
            WHERE Parent_Record_Id__c = :currentEnv.Parent_Record_Id__c
            AND Id != :currentEnv.Id
            AND Envelope_Status__c IN ('Sent', 'Viewed')
            FOR UPDATE
        ];
        if (priorOpenEnvelopes.isEmpty()) {
            return;
        }

        for (ESignature_Envelope__c prior : priorOpenEnvelopes) {
            prior.Envelope_Status__c = 'Canceled';
        }
        update priorOpenEnvelopes;

        String details = 'Envelope canceled because a newer e-signature envelope was sent for this record.';
        for (ESignature_Envelope__c prior : priorOpenEnvelopes) {
            ESignatureUtil.updateSourceFileESignatureStatus(prior, 'Canceled');
            ESignatureUtil.audit(prior.Id, 'Canceled', UserInfo.getUserEmail(), details);
        }
    }

    private static void sendEmail(ESignature_Envelope__c env, String signingUrl) {
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ env.Signer_Email__c });
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        ESignatureUtil.EmailContent content = buildSignatureRequestEmailContent(env, signingUrl, documentTitle);
        message.setSubject(content.subject);
        message.setHtmlBody(content.htmlBody);
        message.setSaveAsActivity(false);
        ESignatureUtil.applyConfiguredOrgWideEmailAddress(message);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
    }

    @TestVisible
    private static String buildSignatureRequestEmailHtml(ESignature_Envelope__c env, String signingUrl, String documentTitle) {
        return buildSignatureRequestEmailContent(env, signingUrl, documentTitle).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildSignatureRequestEmailContent(ESignature_Envelope__c env, String signingUrl, String documentTitle) {
        String signerName = String.isBlank(env.Signer_Name__c) ? 'there' : env.Signer_Name__c;
        String safeSignerName = String.isBlank(env.Signer_Name__c) ? 'there' : ESignatureUtil.escapeHtml(env.Signer_Name__c);
        String resolvedDocumentTitle = String.isBlank(documentTitle) ? 'Document' : documentTitle;
        String safeDocumentTitle = ESignatureUtil.escapeHtml(resolvedDocumentTitle);
        String safeSigningUrl = ESignatureUtil.escapeHtml(signingUrl);
        String senderName = String.isBlank(UserInfo.getName()) ? 'The sender' : UserInfo.getName();
        String safeSenderName = ESignatureUtil.escapeHtml(senderName);
        String expirationDate = formatDateForEmail(env.Expires_At__c == null ? System.now().addDays(365) : env.Expires_At__c);

        String fallbackSubject = 'Signature requested: ' + resolvedDocumentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow('Hi ' + safeSignerName + ',')
            + ESignatureUtil.emailParagraphRow(safeSenderName + ' has sent you a document that requires your signature:')
            + ESignatureUtil.emailDocumentBlockRow('Document', safeDocumentTitle, '#0176d3')
            + ESignatureUtil.emailParagraphRow('Please review and sign the agreement.')
            + ESignatureUtil.emailButtonRow('Review &amp; Sign Document', safeSigningUrl, '#0176d3')
            + ESignatureUtil.emailSubtleRow('This link is unique to you and will expire on ' + expirationDate + '.')
            + ESignatureUtil.emailSubtleRow('If the button above does not work, copy and paste this URL into your browser:<br/><a href="' + safeSigningUrl + '" style="color:#0176d3;text-decoration:underline;word-break:break-all;">' + safeSigningUrl + '</a>')
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Signature_Request',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'SignerName' => signerName,
                'SenderName' => senderName,
                'DocumentTitle' => resolvedDocumentTitle,
                'SigningUrl' => signingUrl,
                'ExpirationDate' => expirationDate
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'SignerName' => safeSignerName,
                'SenderName' => safeSenderName,
                'DocumentTitle' => safeDocumentTitle,
                'SigningUrl' => safeSigningUrl,
                'ExpirationDate' => expirationDate
            }
        );
    }

    private static String formatDateForEmail(Datetime expirationDate) {
        if (expirationDate == null) {
            return '';
        }
        return expirationDate.format('MMMM d, yyyy');
    }
}
