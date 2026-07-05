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
            LIMIT 1
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
    public static SendResultDTO sendEnvelope(String envelopeId, String signerName, String signerEmail, String signerTitle, Integer expirationDays, String requestMessage) {
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
                   Request_Message__c, Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
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
        env.Request_Message__c = normalizedRequestMessage(requestMessage);
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
        sendSalesforceUserSentConfirmation(env, signingUrl);
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
            AND (Envelope_Status__c = null OR Envelope_Status__c IN ('Draft', 'Sent', 'Viewed'))
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

    private static void sendSalesforceUserSentConfirmation(ESignature_Envelope__c env, String signingUrl) {
        String senderEmail = ESignatureUtil.senderEmail(env == null ? null : env.Sender_User__c);
        if (String.isBlank(senderEmail)) {
            return;
        }
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        ESignatureUtil.EmailContent content = buildSalesforceUserSentConfirmationEmailContent(env, signingUrl, documentTitle);
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ senderEmail });
        message.setSubject(content.subject);
        message.setHtmlBody(content.htmlBody);
        message.setSaveAsActivity(false);
        ESignatureUtil.applyConfiguredOrgWideEmailAddress(message);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
        logSentConfirmationActivityAndEmail(env, documentTitle, content, senderEmail);
    }

    private static void logSentConfirmationActivityAndEmail(
        ESignature_Envelope__c env,
        String documentTitle,
        ESignatureUtil.EmailContent content,
        String recipientEmail
    ) {
        Id parentId = ESignatureUtil.safeId(env == null ? null : env.Parent_Record_Id__c);
        if (parentId == null) {
            return;
        }
        String signerDisplay = String.isBlank(env.Signer_Name__c)
            ? env.Signer_Email__c
            : env.Signer_Name__c + ' (' + env.Signer_Email__c + ')';
        Task activity = new Task();
        activity.WhatId = parentId;
        activity.OwnerId = env.Sender_User__c == null ? UserInfo.getUserId() : env.Sender_User__c;
        activity.Subject = 'Email: Signature request sent';
        activity.Status = 'Completed';
        activity.Priority = 'Normal';
        activity.ActivityDate = Date.today();
        activity.Description = 'Signature request sent for ' + (String.isBlank(documentTitle) ? 'Document' : documentTitle)
            + ' to ' + signerDisplay + '.';
        insert activity;

        EmailMessage emailLog = new EmailMessage();
        emailLog.RelatedToId = parentId;
        emailLog.Subject = content == null ? activity.Subject : content.subject;
        emailLog.HtmlBody = content == null ? null : content.htmlBody;
        emailLog.TextBody = activity.Description;
        emailLog.FromAddress = loggedFromAddress();
        emailLog.ToAddress = recipientEmail;
        emailLog.Incoming = false;
        emailLog.Status = '3';
        emailLog.MessageDate = System.now();
        insertEmailLogWithoutBlockingSend(emailLog);
    }

    private static void insertEmailLogWithoutBlockingSend(EmailMessage emailLog) {
        try {
            insert emailLog;
        } catch (DmlException firstFailure) {
            String fallbackFrom = UserInfo.getUserEmail();
            if (!String.isBlank(fallbackFrom) && fallbackFrom != emailLog.FromAddress) {
                try {
                    emailLog.FromAddress = fallbackFrom;
                    insert emailLog;
                } catch (DmlException retryFailure) {}
            }
        }
    }

    private static String loggedFromAddress() {
        try {
            ESignature_Setting__mdt settings = ESignatureUtil.getSettings();
            return ESignatureUtil.firstNonBlank(new List<String>{
                settings.Org_Wide_Email_Address__c,
                settings.Default_From_Email__c,
                UserInfo.getUserEmail()
            });
        } catch (Exception ignore) {
            return UserInfo.getUserEmail();
        }
    }

    @TestVisible
    private static String buildSignatureRequestEmailHtml(ESignature_Envelope__c env, String signingUrl, String documentTitle) {
        return buildSignatureRequestEmailContent(env, signingUrl, documentTitle, null).htmlBody;
    }

    @TestVisible
    private static String buildSignatureRequestEmailHtml(ESignature_Envelope__c env, String signingUrl, String documentTitle, String requestMessage) {
        return buildSignatureRequestEmailContent(env, signingUrl, documentTitle, requestMessage).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildSignatureRequestEmailContent(ESignature_Envelope__c env, String signingUrl, String documentTitle) {
        return buildSignatureRequestEmailContent(env, signingUrl, documentTitle, null);
    }

    private static ESignatureUtil.EmailContent buildSignatureRequestEmailContent(ESignature_Envelope__c env, String signingUrl, String documentTitle, String requestMessageOverride) {
        String signerName = String.isBlank(env.Signer_Name__c) ? 'there' : env.Signer_Name__c;
        String safeSignerName = String.isBlank(env.Signer_Name__c) ? 'there' : ESignatureUtil.escapeHtml(env.Signer_Name__c);
        String resolvedDocumentTitle = String.isBlank(documentTitle) ? 'Document' : documentTitle;
        String safeDocumentTitle = ESignatureUtil.escapeHtml(resolvedDocumentTitle);
        String safeSigningUrl = ESignatureUtil.escapeHtml(signingUrl);
        String senderName = String.isBlank(UserInfo.getName()) ? 'The sender' : UserInfo.getName();
        String safeSenderName = ESignatureUtil.escapeHtml(senderName);
        String requestMessage = resolvedRequestMessage(env, requestMessageOverride);
        String safeRequestMessage = multilineSafeHtml(requestMessage);
        String expirationDate = formatDateForEmail(env.Expires_At__c == null ? System.now().addDays(365) : env.Expires_At__c);
        String emailOpenTrackingUrl = emailOpenTrackingUrl(signingUrl);
        String safeEmailOpenTrackingUrl = ESignatureUtil.escapeHtml(emailOpenTrackingUrl);
        String emailOpenTrackingPixel = emailOpenTrackingPixelHtml(safeEmailOpenTrackingUrl);

        String fallbackSubject = 'Signature requested: ' + resolvedDocumentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow('Hi ' + safeSignerName + ',')
            + ESignatureUtil.emailParagraphRow(safeSenderName + ' has sent you a document that requires your signature:')
            + ESignatureUtil.emailDocumentBlockRow('Document', safeDocumentTitle, '#0176d3')
            + ESignatureUtil.emailParagraphRow(safeRequestMessage)
            + ESignatureUtil.emailButtonRow('Review &amp; Sign Document', safeSigningUrl, '#0176d3')
            + ESignatureUtil.emailSubtleRow('This link is unique to you and will expire on ' + expirationDate + '.')
            + ESignatureUtil.emailSubtleRow('If the button above does not work, copy and paste this URL into your browser:<br/><a href="' + safeSigningUrl + '" style="color:#0176d3;text-decoration:underline;word-break:break-all;">' + safeSigningUrl + '</a>')
            + emailOpenTrackingPixel
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Signature_Request',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'SignerName' => signerName,
                'SenderName' => senderName,
                'DocumentTitle' => resolvedDocumentTitle,
                'RequestMessage' => requestMessage,
                'SigningUrl' => signingUrl,
                'ExpirationDate' => expirationDate,
                'EmailOpenTrackingUrl' => emailOpenTrackingUrl
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'SignerName' => safeSignerName,
                'SenderName' => safeSenderName,
                'DocumentTitle' => safeDocumentTitle,
                'RequestMessage' => safeRequestMessage,
                'RequestMessageHtml' => safeRequestMessage,
                'SigningUrl' => safeSigningUrl,
                'ExpirationDate' => expirationDate,
                'EmailOpenTrackingUrl' => safeEmailOpenTrackingUrl,
                'EmailOpenTrackingPixel' => emailOpenTrackingPixel
            }
        );
    }

    private static String resolvedRequestMessage(ESignature_Envelope__c env, String requestMessageOverride) {
        if (!String.isBlank(requestMessageOverride)) {
            return normalizedRequestMessage(requestMessageOverride);
        }
        return normalizedRequestMessage(envelopeRequestMessage(env));
    }

    private static String envelopeRequestMessage(ESignature_Envelope__c env) {
        if (env == null) {
            return null;
        }
        try {
            return env.Request_Message__c;
        } catch (SObjectException ex) {
            return null;
        }
    }

    private static String normalizedRequestMessage(String requestMessage) {
        return String.isBlank(requestMessage) ? defaultRequestMessage() : requestMessage.trim();
    }

    private static String defaultRequestMessage() {
        return 'Please review and sign the agreement.';
    }

    private static String multilineSafeHtml(String value) {
        return ESignatureUtil.escapeHtml(String.isBlank(value) ? '' : value)
            .replace('\r\n', '<br/>')
            .replace('\n', '<br/>')
            .replace('\r', '<br/>');
    }

    private static String emailOpenTrackingPixelHtml(String safeEmailOpenTrackingUrl) {
        if (String.isBlank(safeEmailOpenTrackingUrl)) {
            return '';
        }
        return '<img src="' + safeEmailOpenTrackingUrl + '" width="1" height="1" alt="" style="display:none;width:1px;height:1px;border:0;outline:none;text-decoration:none;" />';
    }

    private static String emailOpenTrackingUrl(String signingUrl) {
        String token = tokenFromSigningUrl(signingUrl);
        String siteRoot = ESignatureUtil.siteRootUrl(urlWithoutQuery(signingUrl));
        if (String.isBlank(token) || String.isBlank(siteRoot)) {
            return '';
        }
        return siteRoot + '/services/apexrest/ESignature/v1/email-open?t=' + EncodingUtil.urlEncode(token, 'UTF-8');
    }

    private static String urlWithoutQuery(String url) {
        if (String.isBlank(url)) {
            return url;
        }
        Integer queryIndex = url.indexOf('?');
        return queryIndex < 0 ? url : url.substring(0, queryIndex);
    }

    private static String tokenFromSigningUrl(String signingUrl) {
        if (String.isBlank(signingUrl)) {
            return null;
        }
        Integer queryIndex = signingUrl.indexOf('?');
        if (queryIndex < 0 || queryIndex == signingUrl.length() - 1) {
            return null;
        }
        String query = signingUrl.substring(queryIndex + 1);
        for (String pair : query.split('&')) {
            Integer equalsIndex = pair.indexOf('=');
            String key = equalsIndex < 0 ? pair : pair.substring(0, equalsIndex);
            if (key == 't') {
                String value = equalsIndex < 0 ? '' : pair.substring(equalsIndex + 1);
                return EncodingUtil.urlDecode(value, 'UTF-8');
            }
        }
        return null;
    }

    @TestVisible
    private static String buildSalesforceUserSentConfirmationEmailHtml(ESignature_Envelope__c env, String signingUrl, String documentTitle) {
        return buildSalesforceUserSentConfirmationEmailContent(env, signingUrl, documentTitle).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildSalesforceUserSentConfirmationEmailContent(ESignature_Envelope__c env, String signingUrl, String documentTitle) {
        String signerName = env == null || String.isBlank(env.Signer_Name__c) ? 'The signer' : env.Signer_Name__c;
        String signerEmail = env == null ? null : env.Signer_Email__c;
        String signer = ESignatureUtil.escapeHtml(signerName)
            + (String.isBlank(signerEmail) ? '' : ' (' + ESignatureUtil.escapeHtml(signerEmail) + ')');
        String signerText = signerName + (String.isBlank(signerEmail) ? '' : ' (' + signerEmail + ')');
        String resolvedDocumentTitle = String.isBlank(documentTitle) ? 'Document' : documentTitle;
        String safeDocumentTitle = ESignatureUtil.escapeHtml(resolvedDocumentTitle);
        String safeSigningUrl = ESignatureUtil.escapeHtml(signingUrl);
        String expirationDate = formatDateForEmail(env == null || env.Expires_At__c == null ? null : env.Expires_At__c);
        String recordId = env == null ? '' : env.Parent_Record_Id__c;
        String recordObject = env == null ? '' : env.Parent_Object_Api_Name__c;
        String recordUrl = recordUrl(recordId, recordObject);
        String safeRecordId = ESignatureUtil.escapeHtml(recordId);
        String safeRecordUrl = ESignatureUtil.escapeHtml(recordUrl);
        String recordRow = String.isBlank(recordId)
            ? ''
            : ESignatureUtil.emailParagraphRow('<strong>Record:</strong> <a href="' + safeRecordUrl + '" style="color:#0176d3;text-decoration:underline;word-break:break-all;">' + safeRecordId + '</a>');

        String fallbackSubject = 'Signature request sent: ' + resolvedDocumentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow('The signature request was sent.')
            + ESignatureUtil.emailDocumentBlockRow('Document', safeDocumentTitle, '#0176d3')
            + ESignatureUtil.emailParagraphRow('<strong>Signer:</strong> ' + signer)
            + ESignatureUtil.emailParagraphRow('<strong>Status:</strong> Sent')
            + recordRow
            + ESignatureUtil.emailSubtleRow(String.isBlank(expirationDate) ? '' : 'This link is unique to the signer and will expire on ' + expirationDate + '.')
            + ESignatureUtil.emailSubtleRow('Signing URL:<br/><a href="' + safeSigningUrl + '" style="color:#0176d3;text-decoration:underline;word-break:break-all;">' + safeSigningUrl + '</a>')
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Sent_Salesforce_User',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'SignerName' => signerName,
                'SignerEmail' => signerEmail,
                'Signer' => signerText,
                'DocumentTitle' => resolvedDocumentTitle,
                'RecordId' => recordId,
                'Record' => recordUrl,
                'RecordUrl' => recordUrl,
                'RecordObject' => recordObject,
                'SigningUrl' => signingUrl,
                'ExpirationDate' => expirationDate
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'SignerName' => ESignatureUtil.escapeHtml(signerName),
                'SignerEmail' => ESignatureUtil.escapeHtml(signerEmail),
                'Signer' => signer,
                'DocumentTitle' => safeDocumentTitle,
                'RecordId' => safeRecordId,
                'Record' => safeRecordUrl,
                'RecordUrl' => safeRecordUrl,
                'RecordObject' => ESignatureUtil.escapeHtml(recordObject),
                'SigningUrl' => safeSigningUrl,
                'ExpirationDate' => ESignatureUtil.escapeHtml(expirationDate)
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

    private static String formatDateForEmail(Datetime expirationDate) {
        if (expirationDate == null) {
            return '';
        }
        return expirationDate.format('MMMM d, yyyy');
    }
}
