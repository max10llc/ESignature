public without sharing class ESignatureEnvelopeCancellationService {
    public class CancellationResult {
        public Id envelopeId;
        public Boolean success;
        public Boolean canceled;
        public String status;
        public String message;
    }

    private static final Set<String> TERMINAL_STATUSES = new Set<String>{
        'completed',
        'complete',
        'signed',
        'declined',
        'expired'
    };

    public static List<CancellationResult> cancelEnvelopes(Set<Id> envelopeIds, String reason, Boolean sendNotifications) {
        List<CancellationResult> results = new List<CancellationResult>();
        if (envelopeIds == null || envelopeIds.isEmpty()) {
            return results;
        }

        Map<Id, CancellationResult> resultByEnvelopeId = new Map<Id, CancellationResult>();
        for (Id envelopeId : envelopeIds) {
            CancellationResult result = new CancellationResult();
            result.envelopeId = envelopeId;
            result.success = false;
            result.canceled = false;
            result.message = 'Envelope was not found.';
            resultByEnvelopeId.put(envelopeId, result);
            results.add(result);
        }

        Map<Id, ESignature_Envelope__c> envelopeById = new Map<Id, ESignature_Envelope__c>([
            SELECT Id, Name, Status__c, Parent_Record_Id__c, Parent_Object_Api_Name__c,
                   Signer_Name__c, Signer_Email__c, Sender_User__c, Source_File_Title__c,
                   Source_ContentVersion_Id__c, Source_ContentDocument_Id__c
            FROM ESignature_Envelope__c
            WHERE Id IN :envelopeIds
            FOR UPDATE
        ]);

        List<ESignature_Envelope__c> updates = new List<ESignature_Envelope__c>();
        for (ESignature_Envelope__c env : envelopeById.values()) {
            CancellationResult result = resultByEnvelopeId.get(env.Id);
            String status = normalizedStatus(env.Status__c);
            if (isCanceledStatus(status)) {
                result.success = true;
                result.status = 'Canceled';
                result.message = 'Envelope is already canceled.';
                continue;
            }
            if (isTerminalStatus(status)) {
                result.success = false;
                result.status = env.Status__c;
                result.message = 'Envelope cannot be canceled because its current status is ' + env.Status__c + '.';
                continue;
            }
            env.Status__c = 'Canceled';
            env.Cancellation_Reason__c = cancellationReasonValue(reason);
            updates.add(env);
        }

        if (!updates.isEmpty()) {
            Database.SaveResult[] saveResults = Database.update(updates, false);
            for (Integer i = 0; i < saveResults.size(); i++) {
                ESignature_Envelope__c env = updates[i];
                CancellationResult result = resultByEnvelopeId.get(env.Id);
                if (saveResults[i].isSuccess()) {
                    result.success = true;
                    result.canceled = true;
                    result.status = 'Canceled';
                    result.message = 'Envelope canceled.';
                    runPostCancellationWork(env, reason, sendNotifications);
                } else {
                    result.success = false;
                    result.status = normalizedOutputStatus(env.Status__c);
                    result.message = firstDmlError(saveResults[i]);
                }
            }
        }

        return results;
    }

    private static void runPostCancellationWork(ESignature_Envelope__c env, String reason, Boolean sendNotifications) {
        String details = cancellationDetails(reason);
        try {
            ESignatureUtil.updateSourceFileESignatureStatus(env, 'Canceled');
        } catch (Exception ignore) {}
        try {
            ESignatureUtil.audit(env.Id, 'Canceled', UserInfo.getUserEmail(), details);
        } catch (Exception ignore) {}
        if (sendNotifications == false) {
            return;
        }
        sendCancellationNotificationEmails(env, reason);
    }

    private static String cancellationDetails(String reason) {
        String details = 'Envelope canceled manually from Salesforce.';
        if (!String.isBlank(reason)) {
            details += ' Reason: ' + reason.trim();
        }
        return details;
    }

    private static String cancellationReasonValue(String reason) {
        return String.isBlank(reason) ? 'Envelope canceled manually from Salesforce.' : reason.trim();
    }

    private static void sendCancellationNotificationEmails(ESignature_Envelope__c env, String reason) {
        try {
            List<String> recipients = ESignatureUtil.signerAndSenderEmails(env);
            if (recipients.isEmpty()) {
                return;
            }

            ESignatureUtil.EmailContent content = buildCancellationEmailContent(env, reason);
            List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
            for (String recipient : recipients) {
                if (!isValidEmail(recipient)) {
                    continue;
                }
                Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
                message.setToAddresses(new List<String>{ recipient.trim() });
                message.setSubject(content.subject);
                message.setHtmlBody(content.htmlBody);
                message.setSaveAsActivity(false);
                ESignatureUtil.applyConfiguredOrgWideEmailAddress(message);
                messages.add(message);
            }
            if (!messages.isEmpty()) {
                Messaging.sendEmail(messages);
            }
        } catch (Exception ignore) {}
    }

    @TestVisible
    private static String buildCancellationEmailHtml(ESignature_Envelope__c env, String reason) {
        return buildCancellationEmailContent(env, reason).htmlBody;
    }

    private static ESignatureUtil.EmailContent buildCancellationEmailContent(ESignature_Envelope__c env, String reason) {
        String signerName = env == null || String.isBlank(env.Signer_Name__c) ? 'The signer' : env.Signer_Name__c;
        String signerEmail = env == null ? null : env.Signer_Email__c;
        String documentTitle = ESignatureUtil.getEnvelopeTitle(env);
        String cancellationReason = String.isBlank(reason) ? 'No reason was provided.' : reason.trim();
        String escapedReason = ESignatureUtil.escapeHtml(cancellationReason)
            .replace('\r\n', '<br/>')
            .replace('\n', '<br/>')
            .replace('\r', '<br/>');
        String safeSigner = ESignatureUtil.escapeHtml(signerName)
            + (String.isBlank(signerEmail) ? '' : ' (' + ESignatureUtil.escapeHtml(signerEmail) + ')');
        String signerText = displayNameWithEmailText(signerName, signerEmail);
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
        String fallbackSubject = 'Signature request canceled: ' + documentTitle;
        String fallbackHtml = ESignatureUtil.emailShell(
            ESignatureUtil.emailParagraphRow('The signature request was canceled.')
            + ESignatureUtil.emailDocumentBlockRow('Document', ESignatureUtil.escapeHtml(documentTitle), '#b91c1c')
            + ESignatureUtil.emailParagraphRow('<strong>Signer:</strong> ' + safeSigner)
            + ESignatureUtil.emailParagraphRow('<strong>Reason:</strong><br/>' + escapedReason)
            + recordRow
            + ESignatureUtil.emailSubtleRow('No further action is available from the canceled signing link. A new signature request can be sent from Salesforce if needed.')
        );
        return ESignatureUtil.renderEmailTemplate(
            'ESignature_Canceled',
            fallbackSubject,
            fallbackHtml,
            new Map<String, String>{
                'SignerName' => signerName,
                'SignerEmail' => signerEmail,
                'Signer' => signerText,
                'DocumentTitle' => documentTitle,
                'CancellationReason' => cancellationReason,
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
                'Signer' => safeSigner,
                'DocumentTitle' => ESignatureUtil.escapeHtml(documentTitle),
                'CancellationReasonHtml' => escapedReason,
                'RecordId' => safeRecordId,
                'RecordName' => safeRecordName,
                'Record' => safeRecordUrl,
                'RecordUrl' => safeRecordUrl,
                'RecordObject' => ESignatureUtil.escapeHtml(recordObject)
            }
        );
    }

    private static String displayNameWithEmailText(String name, String email) {
        String safeName = String.isBlank(name) ? 'The signer' : name.trim();
        return String.isBlank(email) ? safeName : safeName + ' (' + email.trim() + ')';
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

    private static String normalizedStatus(String status) {
        return String.isBlank(status) ? '' : status.trim().toLowerCase();
    }

    private static String normalizedOutputStatus(String status) {
        return String.isBlank(status) ? null : status.trim();
    }

    private static Boolean isCanceledStatus(String normalizedStatus) {
        return normalizedStatus == 'canceled'
            || normalizedStatus == 'cancelled'
            || normalizedStatus == 'voided'
            || normalizedStatus.contains('cancel');
    }

    private static Boolean isTerminalStatus(String normalizedStatus) {
        return TERMINAL_STATUSES.contains(normalizedStatus)
            || normalizedStatus.contains('complete')
            || normalizedStatus.contains('declin')
            || normalizedStatus.contains('expir')
            || isCanceledStatus(normalizedStatus);
    }

    private static String firstDmlError(Database.SaveResult result) {
        if (result == null || result.getErrors() == null || result.getErrors().isEmpty()) {
            return 'Envelope could not be canceled.';
        }
        return result.getErrors()[0].getMessage();
    }

    private static Boolean isValidEmail(String value) {
        String email = String.isBlank(value) ? null : value.trim();
        return email != null && email.contains('@') && email.contains('.');
    }
}
