public without sharing class ESignatureCommandProcessor {
    private static final String INITIALS_IMAGE_TOKEN = '__ESIGN_INITIALS_IMAGE__';

    private class SubmittedFieldResult {
        String titleValue;
    }

    public static void process(List<ESignature_Command__e> commands) {
        if (commands == null || commands.isEmpty()) {
            return;
        }
        Set<String> tokenHashes = new Set<String>();
        for (ESignature_Command__e command : commands) {
            if (!String.isBlank(command.Token_Hash__c)) {
                tokenHashes.add(command.Token_Hash__c);
            }
        }
        if (tokenHashes.isEmpty()) {
            return;
        }

        Map<String, ESignature_Envelope__c> envelopeByHash = new Map<String, ESignature_Envelope__c>();
        for (ESignature_Envelope__c env : [
            SELECT Id, Name, Status__c, Parent_Record_Id__c, Parent_Object_Api_Name__c,
                   Final_ContentDocument_Id__c, Final_ContentVersion_Id__c, Secure_Token_Hash__c,
                   Signer_Name__c, Signer_Email__c, Signer_Title__c, Sender_User__c,
                   Sent_At__c, Viewed_At__c, Signed_At__c, Expires_At__c, Page_Count__c,
                   Public_Signing_URL__c, Signature_Method__c, Signature_Image_Data_Url__c,
                   Completed_Fields_JSON__c, Completion_Message__c, Decline_Reason__c, Error_Message__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM ESignature_Envelope__c
            WHERE Secure_Token_Hash__c IN :tokenHashes
            FOR UPDATE
        ]) {
            envelopeByHash.put(env.Secure_Token_Hash__c, env);
        }

        for (ESignature_Command__e command : commands) {
            ESignature_Envelope__c env = envelopeByHash.get(command.Token_Hash__c);
            if (env == null) {
                continue;
            }
            Map<String, Object> payload = parsePayload(command.Payload_JSON__c);
            try {
                String action = String.isBlank(command.Action__c) ? '' : command.Action__c.trim().toLowerCase();
                if (action == 'viewed') {
                    handleViewed(env, payload);
                } else if (action == 'email opened' || action == 'email-opened') {
                    handleEmailOpened(env, payload);
                } else if (action == 'disclosure accepted' || action == 'disclosure-accepted') {
                    handleDisclosureAccepted(env, payload);
                } else if (action == 'expired') {
                    handleExpired(env, payload);
                } else if (action == 'signed') {
                    handleSigned(env, payload);
                } else if (action == 'declined') {
                    handleDeclined(env, payload);
                } else if (action == 'delegated') {
                    handleDelegated(env, payload);
                }
            } catch (Exception e) {
                markError(env, payload, e.getMessage() + '\n' + e.getStackTraceString());
            }
        }
    }

    private static void handleViewed(ESignature_Envelope__c env, Map<String, Object> payload) {
        if (env.Expires_At__c != null && env.Expires_At__c < System.now()) {
            handleExpired(env, payload);
            return;
        }
        String status = normalizedEnvelopeStatus(env);
        if (!(status == 'sent' || status == 'viewed' || status == 'error')) {
            return;
        }
        if (status == 'sent') {
            env.Status__c = 'Viewed';
            env.Viewed_At__c = System.now();
            update env;
            audit(env, 'Viewed', payload, 'Signer opened the envelope.');
        } else {
            audit(env, 'Document Opened', payload, 'Signer opened the document signing page.');
        }
        sendSenderEventNotificationEmail(
            env,
            payload,
            'Document Opened',
            'ESignature_Salesforce_User_Document_Opened',
            'Signer opened the document signing page.'
        );
    }

    private static void handleDisclosureAccepted(ESignature_Envelope__c env, Map<String, Object> payload) {
        if (isTerminalEnvelope(env)) {
            return;
        }
        if (env.Expires_At__c != null && env.Expires_At__c < System.now()) {
            handleExpired(env, payload);
            return;
        }
        String status = normalizedEnvelopeStatus(env);
        if (!(status == 'sent' || status == 'viewed' || status == 'error')) {
            return;
        }
        if (hasAuditEvent(env.Id, 'Disclosure Accepted')) {
            return;
        }
        audit(env, 'Disclosure Accepted', payload, 'Signer accepted Consumer Disclosure and consented to use electronic signatures.');
    }

    private static void handleEmailOpened(ESignature_Envelope__c env, Map<String, Object> payload) {
        if (isTerminalEnvelope(env)) {
            return;
        }
        audit(env, 'Email Opened', payload, 'Signer opened the initial signature request email.');
        sendSenderEventNotificationEmail(
            env,
            payload,
            'Email Opened',
            'ESignature_Salesforce_User_Email_Opened',
            'Signer opened the initial signature request email.'
        );
    }

    private static void handleExpired(ESignature_Envelope__c env, Map<String, Object> payload) {
        if (isTerminalEnvelope(env)) {
            return;
        }
        env.Status__c = 'Expired';
        update env;
        ESignatureUtil.updateSourceFileESignatureStatus(env, 'Canceled');
        audit(env, 'Expired', payload, 'Signing link expired when opened.');
    }

    private static void handleDeclined(ESignature_Envelope__c env, Map<String, Object> payload) {
        if (isTerminalEnvelope(env)) {
            return;
        }
        env.Status__c = 'Declined';
        env.Decline_Reason__c = ESignatureUtil.stringValue(payload.get('declineReason'));
        update env;
        ESignatureUtil.updateSourceFileESignatureStatus(env, 'Canceled');
        audit(env, 'Declined', payload, env.Decline_Reason__c);
        sendDeclineNotificationEmail(env);
    }

    private static void handleDelegated(ESignature_Envelope__c env, Map<String, Object> payload) {
        if (isTerminalEnvelope(env)) {
            return;
        }
        if (env.Expires_At__c != null && env.Expires_At__c < System.now()) {
            handleExpired(env, payload);
            return;
        }

        String delegateEmail = trimToNull(ESignatureUtil.stringValue(payload.get('delegateEmail')));
        String delegateName = trimToNull(ESignatureUtil.stringValue(payload.get('delegateName')));
        String delegateMessage = trimToNull(ESignatureUtil.stringValue(payload.get('delegateMessage')));
        if (!isValidEmail(delegateEmail)) {
            throw new ESignatureUtil.AppException('Enter a valid delegate email address.');
        }
        if (String.isBlank(delegateName)) {
            throw new ESignatureUtil.AppException('Delegate name is required.');
        }
        if (String.isBlank(delegateMessage)) {
            throw new ESignatureUtil.AppException('A message is required when delegating this agreement.');
        }

        String previousSignerEmail = env.Signer_Email__c;
        String previousSignerName = env.Signer_Name__c;
        String newToken = ESignatureUtil.generateToken();
        String signingUrl = ESignatureUtil.buildSigningUrl(newToken);

        env.Secure_Token_Hash__c = ESignatureUtil.hashToken(newToken);
        env.Signer_Name__c = delegateName;
        env.Signer_Email__c = delegateEmail;
        env.Signer_Title__c = null;
        env.Status__c = 'Sent';
        env.Sent_At__c = System.now();
        env.Viewed_At__c = null;
        env.Public_Signing_URL__c = signingUrl;
        env.Error_Message__c = null;
        update env;
        ESignatureUtil.updateSourceFileESignatureStatus(env, 'Sent');

        sendDelegateEmails(env, signingUrl, delegateMessage, previousSignerName, previousSignerEmail);
        String previousSigner = String.isBlank(previousSignerName) ? previousSignerEmail : previousSignerName + ' (' + previousSignerEmail + ')';
        String details = 'Delegated from ' + previousSigner + ' to ' + delegateName + ' (' + delegateEmail + '). Message: ' + delegateMessage;
        audit(env, 'Delegated', payload, details, previousSignerEmail);
    }

    private static void handleSigned(ESignature_Envelope__c env, Map<String, Object> payload) {
        if (isTerminalEnvelope(env)) {
            return;
        }
        if (env.Expires_At__c != null && env.Expires_At__c < System.now()) {
            handleExpired(env, payload);
            return;
        }
        String typedName = trimToNull(ESignatureUtil.stringValue(payload.get('typedName')));
        String signerTitle = trimToNull(ESignatureUtil.stringValue(payload.get('signerTitle')));
        if (String.isBlank(typedName)) {
            throw new ESignatureUtil.AppException('Type your full legal name.');
        }

        String signerFieldsJson = ESignatureUtil.stringValue(payload.get('signerFieldsJson'));
        String initialsImageDataUrl = ESignatureUtil.stringValue(payload.get('initialsImageDataUrl'));
        SubmittedFieldResult fieldResult = applySubmittedFields(env, signerFieldsJson, initialsImageDataUrl);
        if (String.isBlank(signerTitle)) {
            signerTitle = fieldResult.titleValue;
        }

        env.Signer_Name__c = typedName;
        env.Signer_Title__c = signerTitle;
        env.Signed_At__c = System.now();
        env.Status__c = 'Finalizing';
        env.Signature_Image_Data_Url__c = ESignatureUtil.stringValue(payload.get('signatureImageDataUrl'));
        env.Signature_Method__c = String.isBlank(env.Signature_Image_Data_Url__c) ? 'Typed' : 'Drawn';
        env.Completed_Fields_JSON__c = signerFieldsJson;
        update env;

        audit(env, 'Signed', payload, 'Signer completed required fields and submitted signature.');
        System.enqueueJob(new ESignatureFinalizeQueueable(env.Id));
    }

    private static Boolean isTerminalEnvelope(ESignature_Envelope__c env) {
        if (env == null) {
            return true;
        }
        if (env.Signed_At__c != null) {
            return true;
        }
        String status = String.isBlank(env.Status__c) ? '' : env.Status__c.trim().toLowerCase();
        return new Set<String>{
            'signed',
            'finalizing',
            'completed',
            'complete',
            'declined',
            'expired',
            'canceled',
            'cancelled',
            'voided'
        }.contains(status)
            || status.contains('cancel')
            || status.contains('void');
    }

    private static String normalizedEnvelopeStatus(ESignature_Envelope__c env) {
        if (env == null) {
            return '';
        }
        String status = ESignatureUtil.stringValue(env.Status__c);
        return String.isBlank(status) ? '' : status.trim().toLowerCase();
    }

    private static Boolean hasAuditEvent(Id envelopeId, String eventType) {
        if (envelopeId == null || String.isBlank(eventType)) {
            return false;
        }
        Integer eventCount = [
            SELECT COUNT()
            FROM ESignature_Audit_Event__c
            WHERE Envelope__c = :envelopeId
            AND Event_Type__c = :eventType
        ];
        return eventCount > 0;
    }

    private static SubmittedFieldResult applySubmittedFields(ESignature_Envelope__c env, String signerFieldsJson, String initialsImageDataUrl) {
        SubmittedFieldResult result = new SubmittedFieldResult();
        Map<Id, String> submittedValues = submittedFieldValueMap(signerFieldsJson, initialsImageDataUrl);
        List<ESignature_Field__c> fields = [
            SELECT Id, Field_Type__c, Label__c, Required__c, Value__c, Completed__c, Completed_At__c
            FROM ESignature_Field__c
            WHERE Envelope__c = :env.Id
        ];
        List<String> missing = new List<String>();
        for (ESignature_Field__c field : fields) {
            String value = submittedValues.get(field.Id);
            Boolean complete = !String.isBlank(value);
            if (field.Field_Type__c == 'Title' && String.isBlank(result.titleValue) && complete) {
                result.titleValue = value.trim();
            }
            if (field.Required__c && !complete) {
                missing.add(String.isBlank(field.Label__c) ? field.Field_Type__c : field.Label__c);
            }
            field.Value__c = value;
            field.Completed__c = complete;
            if (complete) {
                field.Completed_At__c = System.now();
            }
        }
        if (!missing.isEmpty()) {
            throw new ESignatureUtil.AppException('Complete required fields before signing: ' + String.join(missing, ', '));
        }
        if (!fields.isEmpty()) {
            update fields;
        }
        return result;
    }

    @TestVisible
    private static Map<Id, String> submittedFieldValueMap(String rawJson, String initialsImageDataUrl) {
        Map<Id, String> submittedValues = new Map<Id, String>();
        if (!String.isBlank(rawJson)) {
            List<Object> rows = (List<Object>) JSON.deserializeUntyped(rawJson);
            for (Object item : rows) {
                Map<String, Object> row = (Map<String, Object>) item;
                Id fieldId = ESignatureUtil.safeId(ESignatureUtil.stringValue(row.get('id')));
                if (fieldId != null) {
                    String value = ESignatureUtil.stringValue(row.get('value'));
                    if (value == INITIALS_IMAGE_TOKEN) {
                        value = initialsImageDataUrl;
                    }
                    submittedValues.put(fieldId, value);
                }
            }
        }
        return submittedValues;
    }

    private static Map<String, Object> parsePayload(String rawJson) {
        if (String.isBlank(rawJson)) {
            return new Map<String, Object>();
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(rawJson);
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    private static void audit(ESignature_Envelope__c env, String eventType, Map<String, Object> payload, String details) {
        if (env == null || env.Id == null) {
            return;
        }
        ESignature_Audit_Event__c evt = new ESignature_Audit_Event__c();
        evt.Envelope__c = env.Id;
        evt.Event_Type__c = eventType;
        evt.Occurred_At__c = System.now();
        evt.Actor_Email__c = env.Signer_Email__c;
        evt.Details__c = details;
        evt.User_Agent__c = truncate(ESignatureUtil.stringValue(payload.get('userAgent')), 255);
        evt.IP_Address__c = truncate(ESignatureUtil.stringValue(payload.get('ipAddress')), 80);
        insert evt;
    }

    private static void audit(ESignature_Envelope__c env, String eventType, Map<String, Object> payload, String details, String actorEmail) {
        if (env == null || env.Id == null) {
            return;
        }
        ESignature_Audit_Event__c evt = new ESignature_Audit_Event__c();
        evt.Envelope__c = env.Id;
        evt.Event_Type__c = eventType;
        evt.Occurred_At__c = System.now();
        evt.Actor_Email__c = actorEmail;
        evt.Details__c = details;
        evt.User_Agent__c = truncate(ESignatureUtil.stringValue(payload.get('userAgent')), 255);
        evt.IP_Address__c = truncate(ESignatureUtil.stringValue(payload.get('ipAddress')), 80);
        insert evt;
    }

    private static void markError(ESignature_Envelope__c env, Map<String, Object> payload, String message) {
        try {
            env.Status__c = 'Error';
            env.Error_Message__c = truncate(message, 32768);
            update env;
            audit(env, 'Error', payload, truncate(message, 32768));
        } catch (Exception ignore) {}
    }

    private static String trimToNull(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.trim();
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

    private static void sendDelegateEmails(
        ESignature_Envelope__c env,
        String signingUrl,
        String delegateMessage,
        String previousSignerName,
        String previousSignerEmail
    ) {
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();

        addEmailMessage(
            messages,
            env.Signer_Email__c,
            buildDelegateSignerEmailContent(env, signingUrl, delegateMessage, previousSignerName, previousSignerEmail)
        );
        addEmailMessage(
            messages,
            previousSignerEmail,
            buildOriginalSignerDelegationEmailContent(env, delegateMessage, previousSignerName, previousSignerEmail)
        );
        addEmailMessage(
            messages,
            ESignatureUtil.senderEmail(env.Sender_User__c),
            buildSalesforceUserDelegationEmailContent(env, delegateMessage, previousSignerName, previousSignerEmail)
        );

        if (!messages.isEmpty()) {
            Messaging.sendEmail(messages);
        }
    }

    private static void addEmailMessage(List<Messaging.SingleEmailMessage> messages, String recipientEmail, ESignatureUtil.EmailContent content) {
        if (content == null) {
            return;
        }
        addEmailMessage(messages, recipientEmail, content.subject, content.htmlBody);
    }

    private static void addEmailMessage(List<Messaging.SingleEmailMessage> messages, String recipientEmail, String subject, String htmlBody) {
        if (messages == null || !isValidEmail(recipientEmail)) {
            return;
        }
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ recipientEmail.trim() });
        message.setSubject(subject);
        message.setHtmlBody(htmlBody);
        message.setSaveAsActivity(false);
        ESignatureUtil.applyConfiguredOrgWideEmailAddress(message);
        messages.add(message);
    }

    @TestVisible
    private static String buildDelegateSignerEmailHtml(
        ESignature_Envelope__c env,
        String signingUrl,
        String delegateMessage,
        String previousSignerName,
        String previousSignerEmail
    ) {
        return buildDelegateSignerEmailContent(env, signingUrl, delegateMessage, previousSignerName, previousSignerEmail).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildDelegateSignerEmailContent(
        ESignature_Envelope__c env,
        String signingUrl,
        String delegateMessage,
        String previousSignerName,
        String previousSignerEmail
    ) {
        String signerName = env == null || String.isBlank(env.Signer_Name__c) ? 'there' : env.Signer_Name__c;
        String safeSignerName = env == null || String.isBlank(env.Signer_Name__c) ? 'there' : ESignatureUtil.escapeHtml(env.Signer_Name__c);
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        String safeDocumentTitle = ESignatureUtil.escapeHtml(documentTitle);
        String safeSigningUrl = ESignatureUtil.escapeHtml(signingUrl);
        String delegator = displayNameWithEmail(previousSignerName, previousSignerEmail);
        String delegatorText = displayNameWithEmailText(previousSignerName, previousSignerEmail);
        String expirationDate = env == null || env.Expires_At__c == null ? '' : formatDateForEmail(env.Expires_At__c);

        String expirationRow = '';
        String expirationSentence = '';
        if (!String.isBlank(expirationDate)) {
            expirationSentence = 'This link is unique to you and will expire on ' + expirationDate + '.';
            expirationRow = ESignatureUtil.emailSubtleRow(expirationSentence);
        }

        String fallbackSubject = 'Signature requested: ' + documentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow('Hi ' + safeSignerName + ',')
            + ESignatureUtil.emailParagraphRow(delegator + ' delegated a document to you for signature:')
            + ESignatureUtil.emailDocumentBlockRow('Document', safeDocumentTitle, '#0176d3')
            + ESignatureUtil.emailParagraphRow('<strong>Message:</strong><br/>' + multilineSafeHtml(delegateMessage))
            + ESignatureUtil.emailParagraphRow('Please review and sign the agreement.')
            + ESignatureUtil.emailButtonRow('Review &amp; Sign Document', safeSigningUrl, '#0176d3')
            + expirationRow
            + ESignatureUtil.emailSubtleRow('If the button above does not work, copy and paste this URL into your browser:<br/><a href="' + safeSigningUrl + '" style="color:#0176d3;text-decoration:underline;word-break:break-all;">' + safeSigningUrl + '</a>')
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Delegate_Signer_Request',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'SignerName' => signerName,
                'Delegator' => delegatorText,
                'DocumentTitle' => documentTitle,
                'DelegateMessage' => delegateMessage,
                'SigningUrl' => signingUrl,
                'ExpirationDate' => expirationDate,
                'ExpirationSentence' => expirationSentence
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'SignerName' => safeSignerName,
                'Delegator' => delegator,
                'DocumentTitle' => safeDocumentTitle,
                'DelegateMessageHtml' => multilineSafeHtml(delegateMessage),
                'SigningUrl' => safeSigningUrl,
                'ExpirationDate' => ESignatureUtil.escapeHtml(expirationDate),
                'ExpirationSentence' => ESignatureUtil.escapeHtml(expirationSentence)
            }
        );
    }

    @TestVisible
    private static String buildOriginalSignerDelegationEmailHtml(
        ESignature_Envelope__c env,
        String delegateMessage,
        String previousSignerName,
        String previousSignerEmail
    ) {
        return buildOriginalSignerDelegationEmailContent(env, delegateMessage, previousSignerName, previousSignerEmail).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildOriginalSignerDelegationEmailContent(
        ESignature_Envelope__c env,
        String delegateMessage,
        String previousSignerName,
        String previousSignerEmail
    ) {
        String previousSignerDisplay = String.isBlank(previousSignerName) ? 'there' : previousSignerName;
        String safePreviousSignerName = String.isBlank(previousSignerName) ? 'there' : ESignatureUtil.escapeHtml(previousSignerName);
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        String safeDocumentTitle = ESignatureUtil.escapeHtml(documentTitle);
        String delegate = displayNameWithEmail(env == null ? null : env.Signer_Name__c, env == null ? null : env.Signer_Email__c);
        String delegateText = displayNameWithEmailText(env == null ? null : env.Signer_Name__c, env == null ? null : env.Signer_Email__c);

        String fallbackSubject = 'Signature request delegated: ' + documentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow('Hi ' + safePreviousSignerName + ',')
            + ESignatureUtil.emailParagraphRow('Your signature request was delegated to ' + delegate + '.')
            + ESignatureUtil.emailDocumentBlockRow('Document', safeDocumentTitle, '#0176d3')
            + ESignatureUtil.emailParagraphRow('<strong>Message you included:</strong><br/>' + multilineSafeHtml(delegateMessage))
            + ESignatureUtil.emailSubtleRow('Your original signing link is no longer active. The delegated signer received a new signing link.')
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Original_Signer_Delegated',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'PreviousSignerName' => previousSignerDisplay,
                'Delegate' => delegateText,
                'DocumentTitle' => documentTitle,
                'DelegateMessage' => delegateMessage
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'PreviousSignerName' => safePreviousSignerName,
                'Delegate' => delegate,
                'DocumentTitle' => safeDocumentTitle,
                'DelegateMessageHtml' => multilineSafeHtml(delegateMessage)
            }
        );
    }

    @TestVisible
    private static String buildSalesforceUserDelegationEmailHtml(
        ESignature_Envelope__c env,
        String delegateMessage,
        String previousSignerName,
        String previousSignerEmail
    ) {
        return buildSalesforceUserDelegationEmailContent(env, delegateMessage, previousSignerName, previousSignerEmail).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildSalesforceUserDelegationEmailContent(
        ESignature_Envelope__c env,
        String delegateMessage,
        String previousSignerName,
        String previousSignerEmail
    ) {
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        String safeDocumentTitle = ESignatureUtil.escapeHtml(documentTitle);
        String originalSigner = displayNameWithEmail(previousSignerName, previousSignerEmail);
        String originalSignerText = displayNameWithEmailText(previousSignerName, previousSignerEmail);
        String delegate = displayNameWithEmail(env == null ? null : env.Signer_Name__c, env == null ? null : env.Signer_Email__c);
        String delegateText = displayNameWithEmailText(env == null ? null : env.Signer_Name__c, env == null ? null : env.Signer_Email__c);

        String fallbackSubject = 'Signature request delegated: ' + documentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow(originalSigner + ' delegated the signature request to ' + delegate + '.')
            + ESignatureUtil.emailDocumentBlockRow('Document', safeDocumentTitle, '#0176d3')
            + ESignatureUtil.emailParagraphRow('<strong>Delegate message:</strong><br/>' + multilineSafeHtml(delegateMessage))
            + ESignatureUtil.emailSubtleRow('The original signer link is no longer active. The delegated signer received a new signing link.')
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Salesforce_User_Delegated',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'OriginalSigner' => originalSignerText,
                'Delegate' => delegateText,
                'DocumentTitle' => documentTitle,
                'DelegateMessage' => delegateMessage
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'OriginalSigner' => originalSigner,
                'Delegate' => delegate,
                'DocumentTitle' => safeDocumentTitle,
                'DelegateMessageHtml' => multilineSafeHtml(delegateMessage)
            }
        );
    }

    private static void sendSenderEventNotificationEmail(
        ESignature_Envelope__c env,
        Map<String, Object> payload,
        String eventName,
        String templateDeveloperName,
        String details
    ) {
        try {
            String senderEmail = ESignatureUtil.senderEmail(env == null ? null : env.Sender_User__c);
            if (!isValidEmail(senderEmail)) {
                return;
            }
            ESignatureUtil.EmailContent content = buildSenderEventNotificationEmailContent(
                env,
                payload,
                eventName,
                templateDeveloperName,
                details
            );
            Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
            message.setToAddresses(new List<String>{ senderEmail.trim() });
            message.setSubject(content.subject);
            message.setHtmlBody(content.htmlBody);
            message.setSaveAsActivity(false);
            ESignatureUtil.applyConfiguredOrgWideEmailAddress(message);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
        } catch (Exception ignore) {}
    }

    @TestVisible
    private static String buildEmailOpenedNotificationEmailHtml(ESignature_Envelope__c env, Map<String, Object> payload) {
        return buildSenderEventNotificationEmailContent(
            env,
            payload,
            'Email Opened',
            'ESignature_Salesforce_User_Email_Opened',
            'Signer opened the initial signature request email.'
        ).htmlBody;
    }

    @TestVisible
    private static String buildDocumentOpenedNotificationEmailHtml(ESignature_Envelope__c env, Map<String, Object> payload) {
        return buildSenderEventNotificationEmailContent(
            env,
            payload,
            'Document Opened',
            'ESignature_Salesforce_User_Document_Opened',
            'Signer opened the document signing page.'
        ).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildSenderEventNotificationEmailContent(
        ESignature_Envelope__c env,
        Map<String, Object> payload,
        String eventName,
        String templateDeveloperName,
        String details
    ) {
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        String signerName = env == null || String.isBlank(env.Signer_Name__c) ? 'The signer' : env.Signer_Name__c;
        String signerEmail = env == null ? null : env.Signer_Email__c;
        String signer = displayNameWithEmail(signerName, signerEmail);
        String signerText = displayNameWithEmailText(signerName, signerEmail);
        String eventTime = formatDateTimeForEmail(System.now());
        String ipAddress = ESignatureUtil.stringValue(payload == null ? null : payload.get('ipAddress'));
        String userAgent = ESignatureUtil.stringValue(payload == null ? null : payload.get('userAgent'));
        String recordId = env == null ? null : env.Parent_Record_Id__c;
        String recordObject = env == null ? null : env.Parent_Object_Api_Name__c;
        String recordUrl = recordUrl(recordId, recordObject);
        String safeRecordUrl = ESignatureUtil.escapeHtml(recordUrl);
        String safeRecordRow = String.isBlank(recordUrl)
            ? ''
            : ESignatureUtil.emailParagraphRow('<a href="' + safeRecordUrl + '" style="color:#0176d3;text-decoration:underline;word-break:break-all;"><strong>Salesforce Record</strong></a>');

        String fallbackSubject = eventName + ': ' + documentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow(ESignatureUtil.escapeHtml(details))
            + ESignatureUtil.emailDocumentBlockRow('Document', ESignatureUtil.escapeHtml(documentTitle), '#0176d3')
            + ESignatureUtil.emailParagraphRow('<strong>Signer:</strong> ' + signer)
            + ESignatureUtil.emailParagraphRow('<strong>Event:</strong> ' + ESignatureUtil.escapeHtml(eventName))
            + ESignatureUtil.emailParagraphRow('<strong>Time:</strong> ' + ESignatureUtil.escapeHtml(eventTime))
            + safeRecordRow
            + optionalDetailRow('IP Address', ipAddress)
            + optionalDetailRow('User Agent', userAgent)
        );

        return ESignatureUtil.renderEmailTemplate(
            templateDeveloperName,
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'EventName' => eventName,
                'EventTime' => eventTime,
                'SignerName' => signerName,
                'SignerEmail' => signerEmail,
                'Signer' => signerText,
                'DocumentTitle' => documentTitle,
                'Details' => details,
                'IPAddress' => ipAddress,
                'UserAgent' => userAgent,
                'RecordId' => recordId,
                'RecordUrl' => recordUrl,
                'Record' => recordUrl,
                'RecordObject' => recordObject
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'EventName' => ESignatureUtil.escapeHtml(eventName),
                'EventTime' => ESignatureUtil.escapeHtml(eventTime),
                'SignerName' => ESignatureUtil.escapeHtml(signerName),
                'SignerEmail' => ESignatureUtil.escapeHtml(signerEmail),
                'Signer' => signer,
                'DocumentTitle' => ESignatureUtil.escapeHtml(documentTitle),
                'Details' => ESignatureUtil.escapeHtml(details),
                'IPAddress' => ESignatureUtil.escapeHtml(ipAddress),
                'UserAgent' => ESignatureUtil.escapeHtml(userAgent),
                'RecordId' => ESignatureUtil.escapeHtml(recordId),
                'RecordUrl' => safeRecordUrl,
                'Record' => safeRecordUrl,
                'RecordObject' => ESignatureUtil.escapeHtml(recordObject)
            }
        );
    }

    private static String optionalDetailRow(String label, String value) {
        if (String.isBlank(value)) {
            return '';
        }
        return ESignatureUtil.emailSubtleRow('<strong>' + ESignatureUtil.escapeHtml(label) + ':</strong> ' + ESignatureUtil.escapeHtml(value));
    }

    private static String recordUrl(String recordId, String recordObject) {
        if (String.isBlank(recordId)) {
            return '';
        }
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        String root = baseUrl.endsWith('/') ? baseUrl.left(baseUrl.length() - 1) : baseUrl;
        if (String.isBlank(recordObject)) {
            return root + '/' + recordId.trim();
        }
        return root + '/lightning/r/' + EncodingUtil.urlEncode(recordObject.trim(), 'UTF-8') + '/' + recordId.trim() + '/view';
    }

    private static String displayNameWithEmail(String name, String email) {
        if (String.isBlank(name)) {
            return ESignatureUtil.escapeHtml(email);
        }
        if (String.isBlank(email)) {
            return ESignatureUtil.escapeHtml(name);
        }
        return ESignatureUtil.escapeHtml(name) + ' (' + ESignatureUtil.escapeHtml(email) + ')';
    }

    private static String displayNameWithEmailText(String name, String email) {
        if (String.isBlank(name)) {
            return String.isBlank(email) ? '' : email;
        }
        if (String.isBlank(email)) {
            return name;
        }
        return name + ' (' + email + ')';
    }

    private static String multilineSafeHtml(String value) {
        return ESignatureUtil.escapeHtml(value)
            .replace('\r\n', '<br/>')
            .replace('\n', '<br/>')
            .replace('\r', '<br/>');
    }

    private static String formatDateForEmail(Datetime expirationDate) {
        if (expirationDate == null) {
            return '';
        }
        return expirationDate.format('MMMM d, yyyy');
    }

    private static String formatDateTimeForEmail(Datetime value) {
        if (value == null) {
            return '';
        }
        return value.format('MM-dd-yyyy h:mm a');
    }

    private static void sendDeclineNotificationEmail(ESignature_Envelope__c env) {
        try {
            List<String> recipients = declineNotificationRecipients(env);
            if (recipients.isEmpty()) {
                return;
            }
            Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
            message.setToAddresses(recipients);
            ESignatureUtil.EmailContent content = buildDeclineNotificationEmailContent(env);
            message.setSubject(content.subject);
            message.setHtmlBody(content.htmlBody);
            message.setSaveAsActivity(false);
            ESignatureUtil.applyConfiguredOrgWideEmailAddress(message);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
        } catch (Exception ignore) {}
    }

    @TestVisible
    private static List<String> declineNotificationRecipients(ESignature_Envelope__c env) {
        return ESignatureUtil.signerAndSenderEmails(env);
    }

    @TestVisible
    private static String buildDeclineNotificationEmailHtml(ESignature_Envelope__c env) {
        return buildDeclineNotificationEmailContent(env).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildDeclineNotificationEmailContent(ESignature_Envelope__c env) {
        String signerName = env == null || String.isBlank(env.Signer_Name__c) ? 'The signer' : env.Signer_Name__c;
        String signerEmail = env == null ? null : env.Signer_Email__c;
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        String reason = env == null ? null : env.Decline_Reason__c;
        if (String.isBlank(reason)) {
            reason = 'No reason was provided.';
        }
        String escapedReason = ESignatureUtil.escapeHtml(reason)
            .replace('\r\n', '<br/>')
            .replace('\n', '<br/>')
            .replace('\r', '<br/>');

        String safeSigner = ESignatureUtil.escapeHtml(signerName)
            + (String.isBlank(signerEmail) ? '' : ' (' + ESignatureUtil.escapeHtml(signerEmail) + ')');
        String signerText = displayNameWithEmailText(signerName, signerEmail);
        String fallbackSubject = 'Signature request declined: ' + documentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow('The signature request was declined.')
            + ESignatureUtil.emailDocumentBlockRow('Document', ESignatureUtil.escapeHtml(documentTitle), '#b91c1c')
            + ESignatureUtil.emailParagraphRow('<strong>Signer:</strong> ' + safeSigner)
            + ESignatureUtil.emailParagraphRow('<strong>Reason:</strong><br/>' + escapedReason)
            + ESignatureUtil.emailSubtleRow('No further action is available from the declined signing link. A new signature request can be sent from Salesforce if needed.')
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Declined',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'SignerName' => signerName,
                'SignerEmail' => signerEmail,
                'Signer' => signerText,
                'DocumentTitle' => documentTitle,
                'DeclineReason' => reason
            },
            new Map<String, String>{
                'LogoHtml' => ESignatureUtil.emailLogoHtml(),
                'SignerName' => ESignatureUtil.escapeHtml(signerName),
                'SignerEmail' => ESignatureUtil.escapeHtml(signerEmail),
                'Signer' => safeSigner,
                'DocumentTitle' => ESignatureUtil.escapeHtml(documentTitle),
                'DeclineReasonHtml' => escapedReason
            }
        );
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null || maxLength == null || value.length() <= maxLength) {
            return value;
        }
        return value.left(maxLength);
    }
}
