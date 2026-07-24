public without sharing class ESignatureUtil {
    private static final Integer SOURCE_PDF_CHUNK_SIZE = 100000;
    public class AppException extends Exception {}
    public class EmailContent {
        public String subject;
        public String htmlBody;
        public String textBody;

        public EmailContent(String subject, String htmlBody, String textBody) {
            this.subject = subject;
            this.htmlBody = htmlBody;
            this.textBody = textBody;
        }
    }

    public static ESignature_Setting__mdt getSettings() {
        ESignature_Setting__mdt settings = ESignature_Setting__mdt.getInstance('Default');
        if (settings == null) {
            throw new AppException('Missing ESignature_Setting__mdt record named Default.');
        }
        return settings;
    }

    public static String generateToken() {
        Blob key = Crypto.generateAesKey(256);
        return EncodingUtil.convertToHex(key) + EncodingUtil.convertToHex(Crypto.generateAesKey(128));
    }

    public static String hashToken(String token) {
        if (String.isBlank(token)) {
            return null;
        }
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(token)));
    }

    public static void updateEnvelopeSigningSecrets(Id envelopeId, String tokenHash) {
        if (envelopeId == null) {
            throw new AppException('Envelope Id is required to update signing secrets.');
        }
        ESignature_Envelope__c updateRow = new ESignature_Envelope__c(
            Id = envelopeId,
            Secure_Token_Hash__c = tokenHash,
            Public_Signing_URL__c = null
        );
        Database.update(updateRow, AccessLevel.SYSTEM_MODE);
    }

    public static ESignature_Envelope__c findEnvelopeByToken(String token) {
        String hashValue = hashToken(token);
        if (String.isBlank(hashValue)) {
            return null;
        }
        List<ESignature_Envelope__c> rows = [
            SELECT Id, Name, Status__c, Parent_Record_Id__c, Parent_Object_Api_Name__c,
                   Final_ContentDocument_Id__c, Final_ContentVersion_Id__c, Secure_Token_Hash__c,
                   Signer_Name__c, Signer_Email__c, Signer_Title__c, Sender_User__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c,
                   Sent_At__c, Viewed_At__c, Signed_At__c, Expires_At__c, Page_Count__c,
                   Signature_Method__c, Signature_Image_Data_Url__c,
                   Completed_Fields_JSON__c, Completion_Message__c, Request_Message__c,
                   Decline_Reason__c, Error_Message__c
            FROM ESignature_Envelope__c
            WHERE Secure_Token_Hash__c = :hashValue
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    public static Id getEnvelopeSourceDocumentId(Id envelopeId) {
        if (envelopeId == null) {
            return null;
        }
        List<ESignature_Field__c> fields = [
            SELECT Content_Document_Id__c
            FROM ESignature_Field__c
            WHERE Envelope__c = :envelopeId
            AND Content_Document_Id__c != null
            ORDER BY Sequence__c ASC, CreatedDate ASC
            LIMIT 1
        ];
        if (fields.isEmpty()) {
            return null;
        }
        return safeId(fields[0].Content_Document_Id__c);
    }

    public static Id getEnvelopeSourceVersionId(Id envelopeId) {
        if (envelopeId == null) {
            return null;
        }
        List<ESignature_Field__c> fields = [
            SELECT Content_Version_Id__c
            FROM ESignature_Field__c
            WHERE Envelope__c = :envelopeId
            AND Content_Version_Id__c != null
            ORDER BY Sequence__c ASC, CreatedDate ASC
            LIMIT 1
        ];
        if (fields.isEmpty()) {
            return null;
        }
        return safeId(fields[0].Content_Version_Id__c);
    }

    public static Map<Id, Id> getSourceDocumentIdsByEnvelopeId(Set<Id> envelopeIds) {
        Map<Id, Id> output = new Map<Id, Id>();
        if (envelopeIds == null || envelopeIds.isEmpty()) {
            return output;
        }
        for (ESignature_Field__c field : [
            SELECT Envelope__c, Content_Document_Id__c
            FROM ESignature_Field__c
            WHERE Envelope__c IN :envelopeIds
            AND Content_Document_Id__c != null
            ORDER BY Sequence__c ASC, CreatedDate ASC
        ]) {
            if (field.Envelope__c != null && !output.containsKey(field.Envelope__c)) {
                Id docId = safeId(field.Content_Document_Id__c);
                if (docId != null) {
                    output.put(field.Envelope__c, docId);
                }
            }
        }
        return output;
    }

    public static String getEnvelopeTitle(ESignature_Envelope__c env) {
        if (env == null) {
            return 'Document';
        }
        String fallback = String.isBlank(env.Name) ? 'Document' : env.Name;
        String storedSourceTitle = getEnvelopeString(env, 'Source_File_Title__c');
        if (!String.isBlank(storedSourceTitle)) {
            return storedSourceTitle;
        }
        ContentVersion latest = getLatestSourceVersion(env, false);
        if (latest != null && !String.isBlank(latest.Title)) {
            return latest.Title;
        }
        return fallback;
    }

    public static ContentVersion getLatestSourceVersion(ESignature_Envelope__c env, Boolean includeData) {
        if (env == null) {
            return null;
        }

        // Public Site requests are running as the Site Guest User.  Querying the
        // file by ContentDocumentId can return no rows or throw in that context,
        // even though the signing envelope itself is visible.  The prepared field
        // rows store the exact ContentVersion Id, so try that first, then fall
        // back to the latest version by ContentDocumentId for internal/admin use.
        ContentVersion sourceByVersionId = getContentVersionById(safeId(getEnvelopeString(env, 'Source_ContentVersion_Id__c')), includeData);
        if (sourceByVersionId != null) {
            return sourceByVersionId;
        }

        sourceByVersionId = getContentVersionById(getEnvelopeSourceVersionId(env.Id), includeData);
        if (sourceByVersionId != null) {
            return sourceByVersionId;
        }

        Id documentId = safeId(getEnvelopeString(env, 'Source_ContentDocument_Id__c'));
        if (documentId == null) {
            documentId = getEnvelopeSourceDocumentId(env.Id);
        }
        return getLatestContentVersion(documentId, includeData);
    }

    private static String getEnvelopeString(ESignature_Envelope__c env, String fieldName) {
        if (env == null || String.isBlank(fieldName)) {
            return null;
        }
        try {
            return stringValue(env.get(fieldName));
        } catch (Exception ignore) {
            return null;
        }
    }

    public static ContentVersion getContentVersionById(Id contentVersionId, Boolean includeData) {
        if (contentVersionId == null) {
            return null;
        }
        try {
            if (includeData == true) {
                List<ContentVersion> versions = [
                    SELECT Id, ContentDocumentId, Title, FileExtension, VersionData
                    FROM ContentVersion
                    WHERE Id = :contentVersionId
                    LIMIT 1
                ];
                return versions.isEmpty() ? null : versions[0];
            }
            List<ContentVersion> versions = [
                SELECT Id, ContentDocumentId, Title, FileExtension
                FROM ContentVersion
                WHERE Id = :contentVersionId
                LIMIT 1
            ];
            return versions.isEmpty() ? null : versions[0];
        } catch (Exception ignore) {
            return null;
        }
    }

    public static ContentVersion getLatestContentVersion(Id documentId, Boolean includeData) {
        if (documentId == null) {
            return null;
        }
        try {
            if (includeData == true) {
                List<ContentVersion> versions = [
                    SELECT Id, ContentDocumentId, Title, FileExtension, VersionData
                    FROM ContentVersion
                    WHERE ContentDocumentId = :documentId
                    AND IsLatest = true
                    LIMIT 1
                ];
                return versions.isEmpty() ? null : versions[0];
            }
            List<ContentVersion> versions = [
                SELECT Id, ContentDocumentId, Title, FileExtension
                FROM ContentVersion
                WHERE ContentDocumentId = :documentId
                AND IsLatest = true
                LIMIT 1
            ];
            return versions.isEmpty() ? null : versions[0];
        } catch (Exception ignore) {
            return null;
        }
    }


    public static void cacheSourcePdfForEnvelope(Id envelopeId) {
        if (envelopeId == null) {
            throw new AppException('Envelope Id is required to cache the source PDF.');
        }

        ESignature_Envelope__c env = new ESignature_Envelope__c(Id = envelopeId);
        ContentVersion source = getLatestSourceVersion(env, true);
        if (source == null || source.VersionData == null) {
            throw new AppException('Unable to cache source PDF because the source ContentVersion could not be read.');
        }

        delete [
            SELECT Id
            FROM ESignature_Source_Chunk__c
            WHERE Envelope__c = :envelopeId
        ];

        String encoded = EncodingUtil.base64Encode(source.VersionData);
        List<ESignature_Source_Chunk__c> chunks = new List<ESignature_Source_Chunk__c>();
        Integer sequence = 1;
        for (Integer index = 0; index < encoded.length(); index += SOURCE_PDF_CHUNK_SIZE) {
            Integer endIndex = Math.min(index + SOURCE_PDF_CHUNK_SIZE, encoded.length());
            chunks.add(new ESignature_Source_Chunk__c(
                Envelope__c = envelopeId,
                Sequence__c = sequence,
                Content_Version_Id__c = String.valueOf(source.Id),
                Content_Document_Id__c = String.valueOf(source.ContentDocumentId),
                Data__c = encoded.substring(index, endIndex)
            ));
            sequence++;
        }
        if (!chunks.isEmpty()) {
            insert chunks;
        }
    }

    public static Blob getCachedSourcePdfBlob(Id envelopeId) {
        if (envelopeId == null) {
            return null;
        }
        try {
            List<ESignature_Source_Chunk__c> chunks = [
                SELECT Sequence__c, Data__c
                FROM ESignature_Source_Chunk__c
                WHERE Envelope__c = :envelopeId
                ORDER BY Sequence__c ASC
            ];
            if (chunks.isEmpty()) {
                return null;
            }
            String encoded = '';
            for (ESignature_Source_Chunk__c chunk : chunks) {
                if (chunk.Data__c != null) {
                    encoded += chunk.Data__c;
                }
            }
            if (String.isBlank(encoded)) {
                return null;
            }
            return EncodingUtil.base64Decode(encoded);
        } catch (Exception ignore) {
            return null;
        }
    }

    public static Map<Id, String> getContentDocumentTitles(Set<Id> documentIds) {
        Map<Id, String> output = new Map<Id, String>();
        if (documentIds == null || documentIds.isEmpty()) {
            return output;
        }
        for (ContentVersion version : [
            SELECT ContentDocumentId, Title
            FROM ContentVersion
            WHERE ContentDocumentId IN :documentIds
            AND IsLatest = true
        ]) {
            output.put(version.ContentDocumentId, version.Title);
        }
        return output;
    }

    public static void updateSourceFileESignatureStatus(ESignature_Envelope__c env, String status) {
        if (env == null || String.isBlank(status)) {
            return;
        }
        Id contentVersionId = safeId(getEnvelopeString(env, 'Source_ContentVersion_Id__c'));
        if (contentVersionId == null) {
            contentVersionId = getEnvelopeSourceVersionId(env.Id);
        }
        if (contentVersionId == null) {
            Id documentId = safeId(getEnvelopeString(env, 'Source_ContentDocument_Id__c'));
            ContentVersion latest = getLatestContentVersion(documentId, false);
            contentVersionId = latest == null ? null : latest.Id;
        }
        updateContentVersionESignatureStatus(contentVersionId, status);
    }

    public static void updateContentVersionESignatureStatus(Id contentVersionId, String status) {
        if (contentVersionId == null || String.isBlank(status)) {
            return;
        }
        try {
            update new ContentVersion(
                Id = contentVersionId,
                ESignature_Status__c = status
            );
        } catch (Exception ignore) {}
    }

    public static String titleFromEnvelope(ESignature_Envelope__c env, Map<Id, String> titleByDocumentId, Map<Id, Id> documentIdByEnvelopeId) {
        if (env == null) {
            return 'Document';
        }
        Id documentId = documentIdByEnvelopeId == null ? null : documentIdByEnvelopeId.get(env.Id);
        if (documentId != null && titleByDocumentId != null && titleByDocumentId.containsKey(documentId)
            && !String.isBlank(titleByDocumentId.get(documentId))) {
            return titleByDocumentId.get(documentId);
        }
        return String.isBlank(env.Name) ? 'Document' : env.Name;
    }

    public static String titleFromEnvelope(ESignature_Envelope__c env, Map<Id, String> titleByDocumentId) {
        Map<Id, Id> byEnvelope = new Map<Id, Id>();
        if (env != null) {
            byEnvelope.put(env.Id, getEnvelopeSourceDocumentId(env.Id));
        }
        return titleFromEnvelope(env, titleByDocumentId, byEnvelope);
    }

    public static void audit(Id envelopeId, String eventType, String actorEmail, String details) {
        if (envelopeId == null) {
            return;
        }
        ESignature_Audit_Event__c evt = new ESignature_Audit_Event__c();
        evt.Envelope__c = envelopeId;
        evt.Event_Type__c = eventType;
        evt.Occurred_At__c = System.now();
        evt.Actor_Email__c = actorEmail;
        evt.Details__c = details;
        try {
            if (ApexPages.currentPage() != null) {
                Map<String, String> headers = ApexPages.currentPage().getHeaders();
                evt.User_Agent__c = headers.get('User-Agent');
                evt.IP_Address__c = headers.get('True-Client-IP');
                if (String.isBlank(evt.IP_Address__c)) {
                    evt.IP_Address__c = headers.get('X-Salesforce-SIP');
                }
                if (String.isBlank(evt.IP_Address__c)) {
                    evt.IP_Address__c = headers.get('X-Forwarded-For');
                }
            }
        } catch (Exception ignore) {}
        insert evt;
    }

    public static void stampEnvelopeParent(ESignature_Envelope__c env, String parentRecordId) {
        if (env == null) {
            return;
        }
        Id parentId = safeId(parentRecordId);
        env.Parent_Record_Id__c = parentId == null ? normalizeRecordIdString(parentRecordId) : String.valueOf(parentId);
        String parentObjectApiName = parentId == null ? null : parentId.getSObjectType().getDescribe().getName();
        env.Parent_Object_Api_Name__c = parentObjectApiName;
        env.Account__c = null;
        env.Case__c = null;
        env.Opportunity__c = null;
        env.Work_Order__c = null;
        if (parentId == null || String.isBlank(parentObjectApiName)) {
            return;
        }
        if (parentObjectApiName == 'Account') {
            env.Account__c = parentId;
        } else if (parentObjectApiName == 'Case') {
            env.Case__c = parentId;
        } else if (parentObjectApiName == 'Opportunity') {
            env.Opportunity__c = parentId;
        } else if (parentObjectApiName == 'WorkOrder') {
            env.Work_Order__c = parentId;
        }
    }

    public static String parentRecordName(String parentRecordId, String parentObjectApiName) {
        Id parentId = safeId(parentRecordId);
        if (parentId == null) {
            return String.isBlank(parentRecordId) ? '' : parentRecordId.trim();
        }

        try {
            Schema.SObjectType objectType = parentId.getSObjectType();
            if (objectType == null && !String.isBlank(parentObjectApiName)) {
                objectType = Schema.getGlobalDescribe().get(parentObjectApiName.trim());
            }
            if (objectType == null) {
                return String.valueOf(parentId);
            }

            Schema.DescribeSObjectResult describe = objectType.getDescribe();
            Map<String, Schema.SObjectField> fields = describe.fields.getMap();
            String nameField = null;
            for (String fieldName : fields.keySet()) {
                Schema.DescribeFieldResult fieldDescribe = fields.get(fieldName).getDescribe();
                if (fieldDescribe.isNameField()) {
                    nameField = fieldDescribe.getName();
                    break;
                }
            }
            if (String.isBlank(nameField) && fields.containsKey('Name')) {
                nameField = 'Name';
            }
            if (String.isBlank(nameField)) {
                return String.valueOf(parentId);
            }

            List<SObject> rows = Database.query(
                'SELECT ' + nameField +
                ' FROM ' + describe.getName() +
                ' WHERE Id = :parentId LIMIT 1'
            );
            if (rows.isEmpty()) {
                return String.valueOf(parentId);
            }
            String recordName = stringValue(rows[0].get(nameField));
            return String.isBlank(recordName) ? String.valueOf(parentId) : recordName;
        } catch (Exception ignore) {
            return String.valueOf(parentId);
        }
    }

    public static String normalizeRecordIdString(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        Id parsedId = safeId(value);
        return parsedId == null ? value.trim() : String.valueOf(parsedId);
    }

    public static Set<String> parentRecordIdValues(String value) {
        Set<String> output = new Set<String>();
        if (String.isBlank(value)) {
            return output;
        }
        String trimmed = value.trim();
        output.add(trimmed);
        Id parsedId = safeId(trimmed);
        if (parsedId != null) {
            String normalized = String.valueOf(parsedId);
            output.add(normalized);
            if (normalized.length() == 18) {
                output.add(normalized.substring(0, 15));
            }
        }
        return output;
    }

    public static Id safeId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            Id output = value.trim();
            return output;
        } catch (Exception e) {
            return null;
        }
    }

    public static Integer intValue(Object value, Integer defaultValue) {
        if (value == null) {
            return defaultValue;
        }
        try {
            return Integer.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return defaultValue;
        }
    }

    public static Decimal decimalValue(Object value, Decimal defaultValue) {
        if (value == null) {
            return defaultValue;
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return defaultValue;
        }
    }

    public static Boolean boolValue(Object value, Boolean defaultValue) {
        if (value == null) {
            return defaultValue;
        }
        String s = String.valueOf(value).trim().toLowerCase();
        if (s == 'true' || s == '1' || s == 'yes') {
            return true;
        }
        if (s == 'false' || s == '0' || s == 'no') {
            return false;
        }
        return defaultValue;
    }

    public static String stringValue(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    public static String escapeHtml(String value) {
        return value == null ? '' : value.escapeHtml4();
    }

    public static String normalizeBaseUrl(String url) {
        if (String.isBlank(url)) {
            return null;
        }
        String output = url.trim();
        while (output.endsWith('/')) {
            output = output.left(output.length() - 1);
        }
        return output;
    }

    public static String siteRootUrl(String url) {
        String output = normalizeBaseUrl(url);
        if (String.isBlank(output)) {
            return null;
        }
        if (output.endsWith('/apex/ESignaturePage')) {
            output = output.left(output.length() - '/apex/ESignaturePage'.length());
        } else if (output.endsWith('/ESignaturePage')) {
            output = output.left(output.length() - '/ESignaturePage'.length());
        }
        if (output.endsWith('/apex')) {
            output = output.left(output.length() - '/apex'.length());
        }
        return normalizeBaseUrl(output);
    }

    public static String siteApexUrl(String url) {
        String root = siteRootUrl(url);
        if (String.isBlank(root)) {
            return null;
        }
        return root + '/apex';
    }

    public static String buildSigningUrl(String token) {
        ESignature_Setting__mdt settings = getSettings();
        String apexBaseUrl = siteApexUrl(settings.Site_Base_URL__c);
        if (String.isBlank(apexBaseUrl)) {
            throw new AppException('Set ESignature_Setting.Default.Site_Base_URL__c before sending an envelope. Use the public Site URL, for example https://domain.my.site.com/signatures.');
        }
        return apexBaseUrl + '/ESignaturePage?t=' + EncodingUtil.urlEncode(token, 'UTF-8');
    }

    public static String buildPdfResourceUrl(String token) {
        // Kept for backward compatibility.  The public Visualforce signer page now
        // builds this URL with $Site.Prefix so the Site path, for example
        // /signatures, is preserved for Site Guest User REST requests.
        String encodedToken = EncodingUtil.urlEncode(token, 'UTF-8');
        return '/services/apexrest/ESignature/v1/pdf?t=' + encodedToken;
    }

    public static String buildFinalizerCallbackUrl(ESignature_Setting__mdt settings) {
        if (settings != null && !String.isBlank(settings.Finalizer_Callback_URL__c)) {
            return settings.Finalizer_Callback_URL__c.trim();
        }
        String root = settings == null ? null : siteRootUrl(settings.Site_Base_URL__c);
        if (String.isBlank(root)) {
            return null;
        }
        return root + '/services/apexrest/ESignature/v1/finalizer-callback';
    }

    public static void applyConfiguredOrgWideEmailAddress(Messaging.SingleEmailMessage message) {
        if (message == null) {
            return;
        }
        try {
            ESignature_Setting__mdt settings = getSettings();
            message.setUseSignature(includeUserEmailSignature(settings));
            Id orgWideEmailAddressId = configuredOrgWideEmailAddressId(settings);
            if (orgWideEmailAddressId == null) {
                orgWideEmailAddressId = orgWideEmailAddressId(configuredOrgWideEmailAddress(settings));
            }
            if (orgWideEmailAddressId != null) {
                message.setOrgWideEmailAddressId(orgWideEmailAddressId);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Unable to apply configured org-wide email address: ' + e.getMessage());
        }
    }

    @TestVisible
    private static String configuredOrgWideEmailAddress(ESignature_Setting__mdt settings) {
        if (settings == null) {
            return null;
        }
        return firstNonBlank(new List<String>{
            settings.Org_Wide_Email_Address__c,
            settings.Default_From_Email__c
        });
    }

    @TestVisible
    private static Id configuredOrgWideEmailAddressId(ESignature_Setting__mdt settings) {
        if (settings == null || String.isBlank(settings.Org_Wide_Email_Address_Id__c)) {
            return null;
        }
        try {
            return (Id) settings.Org_Wide_Email_Address_Id__c.trim();
        } catch (Exception ignore) {
            return null;
        }
    }

    @TestVisible
    private static Boolean includeUserEmailSignature(ESignature_Setting__mdt settings) {
        return settings != null && settings.Include_User_Email_Signature__c == true;
    }

    private static Id orgWideEmailAddressId(String emailAddress) {
        if (String.isBlank(emailAddress)) {
            return null;
        }
        List<OrgWideEmailAddress> rows = [
            SELECT Id
            FROM OrgWideEmailAddress
            WHERE Address = :emailAddress.trim()
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].Id;
    }

    public static String configuredEmailLogoUrl() {
        try {
            return configuredEmailLogoUrl(getSettings());
        } catch (Exception ignore) {
            return null;
        }
    }

    public static EmailContent renderEmailTemplate(
        String templateDeveloperName,
        String fallbackSubject,
        String fallbackHtmlBody,
        Map<String, String> textTokens,
        Map<String, String> htmlTokens
    ) {
        EmailContent content = new EmailContent(fallbackSubject, fallbackHtmlBody, null);
        try {
            if (!String.isBlank(templateDeveloperName)) {
                List<EmailTemplate> templates = [
                    SELECT Subject, HtmlValue, Body
                    FROM EmailTemplate
                    WHERE DeveloperName = :templateDeveloperName
                    AND IsActive = true
                    LIMIT 1
                ];
                if (!templates.isEmpty()) {
                    EmailTemplate template = templates[0];
                    content.subject = String.isBlank(template.Subject) ? fallbackSubject : template.Subject;
                    content.htmlBody = String.isBlank(template.HtmlValue)
                        ? plainTextToHtml(template.Body)
                        : template.HtmlValue;
                    content.textBody = template.Body;
                }
            }
        } catch (Exception ignore) {}

        content.subject = replaceEmailTemplateTokens(content.subject, textTokens);
        content.htmlBody = replaceEmailTemplateTokens(content.htmlBody, htmlTokens);
        content.textBody = replaceEmailTemplateTokens(content.textBody, textTokens);
        return content;
    }

    public static String replaceEmailTemplateTokens(String value, Map<String, String> tokens) {
        if (value == null) {
            return '';
        }
        String output = value;
        if (tokens == null) {
            return output;
        }
        for (String key : tokens.keySet()) {
            output = output.replace('{{' + key + '}}', tokens.get(key) == null ? '' : tokens.get(key));
        }
        return output;
    }

    private static String plainTextToHtml(String textBody) {
        if (String.isBlank(textBody)) {
            return '';
        }
        return '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:20px;color:#374151;">'
            + escapeHtml(textBody)
                .replace('\r\n', '<br/>')
                .replace('\n', '<br/>')
                .replace('\r', '<br/>')
            + '</div>';
    }

    @TestVisible
    private static String configuredEmailLogoUrl(ESignature_Setting__mdt settings) {
        return settings == null || String.isBlank(settings.Email_Logo_URL__c)
            ? null
            : settings.Email_Logo_URL__c.trim();
    }

    public static String emailLogoHtml() {
        String logoUrl = configuredEmailLogoUrl();
        return String.isBlank(logoUrl)
            ? 'E-Signature'
            : '<img src="' + escapeHtml(logoUrl) + '" width="252" height="73" alt="Kaizon Solutions" style="display:block;width:252px;max-width:252px;height:73px;border:0;outline:none;text-decoration:none;-ms-interpolation-mode:bicubic;" />';
    }

    public static String emailShell(String contentHtml) {
        return ''
            + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;background-color:#ffffff;margin:0;padding:0;border-collapse:collapse;">'
            + '  <tr>'
            + '    <td align="center" style="padding:24px 10px 24px 10px;">'
            + '      <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;background-color:#ffffff;border:1px solid #e5e7eb;border-collapse:collapse;">'
            + emailHeaderRow()
            +          nullToBlank(contentHtml)
            + '      </table>'
            + '    </td>'
            + '  </tr>'
            + '</table>';
    }

    private static String emailHeaderRow() {
        return ''
            + '        <tr>'
            + '          <td bgcolor="#0176d3" height="44" style="height:44px;background-color:#0176d3;font-size:0;line-height:44px;mso-line-height-rule:exactly;">&nbsp;</td>'
            + '        </tr>'
            + '        <tr>'
            + '          <td align="left" style="padding:18px 24px 14px 24px;border-bottom:1px solid #e5e7eb;">'
            +              emailLogoHtml()
            + '          </td>'
            + '        </tr>';
    }

    public static String emailRow(String innerHtml) {
        return '<tr><td style="padding:0 24px 16px 24px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:20px;color:#374151;">' + nullToBlank(innerHtml) + '</td></tr>';
    }

    public static String emailParagraphRow(String safeHtml) {
        return emailRow('<p style="Margin:0;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:20px;color:#374151;">' + nullToBlank(safeHtml) + '</p>');
    }

    public static String emailSubtleRow(String safeHtml) {
        return emailRow('<p style="Margin:0;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:18px;color:#64748b;">' + nullToBlank(safeHtml) + '</p>');
    }

    public static String emailDocumentBlockRow(String label, String safeTitle, String accentColor) {
        String color = String.isBlank(accentColor) ? '#0176d3' : accentColor;
        return ''
            + '<tr>'
            + '  <td style="padding:0 24px 18px 24px;">'
            + '    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;background-color:#f7f8fa;border-left:4px solid ' + color + ';">'
            + '      <tr>'
            + '        <td style="padding:13px 16px;font-family:Arial,Helvetica,sans-serif;">'
            + '          <div style="font-size:12px;line-height:16px;color:#64748b;Margin:0 0 6px 0;">' + escapeHtml(label) + '</div>'
            + '          <div style="font-size:15px;line-height:20px;font-weight:bold;color:#111827;Margin:0;">' + nullToBlank(safeTitle) + '</div>'
            + '        </td>'
            + '      </tr>'
            + '    </table>'
            + '  </td>'
            + '</tr>';
    }

    public static String emailButtonRow(String safeLabel, String safeUrl, String backgroundColor) {
        String color = String.isBlank(backgroundColor) ? '#0176d3' : backgroundColor;
        return ''
            + '<tr>'
            + '  <td align="center" style="padding:8px 24px 22px 24px;">'
            + '    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
            + '      <tr>'
            + '        <td bgcolor="' + color + '" style="background-color:' + color + ';padding:0;">'
            + '          <a href="' + nullToBlank(safeUrl) + '" target="_blank" style="display:block;padding:12px 24px;background-color:' + color + ';color:#ffffff;text-decoration:none;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:18px;font-weight:bold;text-align:center;">' + nullToBlank(safeLabel) + '</a>'
            + '        </td>'
            + '      </tr>'
            + '    </table>'
            + '  </td>'
            + '</tr>';
    }

    private static String nullToBlank(String value) {
        return value == null ? '' : value;
    }

    public static List<String> signerAndSenderEmails(ESignature_Envelope__c env) {
        Set<String> recipients = new Set<String>();
        addEmail(recipients, env == null ? null : env.Signer_Email__c);
        addEmail(recipients, senderEmail(env == null ? null : env.Sender_User__c));
        List<String> output = new List<String>();
        output.addAll(recipients);
        output.sort();
        return output;
    }

    private static void addEmail(Set<String> recipients, String email) {
        String normalized = String.isBlank(email) ? null : email.trim();
        if (normalized != null) {
            recipients.add(normalized);
        }
    }

    public static String senderEmail(Id userId) {
        if (userId == null) {
            return null;
        }
        List<User> users = [
            SELECT Email
            FROM User
            WHERE Id = :userId
            LIMIT 1
        ];
        return users.isEmpty() ? null : users[0].Email;
    }

    public static void addCurrentRequestContext(Map<String, Object> payload) {
        if (payload == null) {
            return;
        }
        payload.put('serverTimestamp', System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        try {
            if (ApexPages.currentPage() != null) {
                Map<String, String> headers = ApexPages.currentPage().getHeaders();
                payload.put('userAgent', headers.get('User-Agent'));
                String ipAddress = headers.get('True-Client-IP');
                if (String.isBlank(ipAddress)) {
                    ipAddress = headers.get('X-Salesforce-SIP');
                }
                if (String.isBlank(ipAddress)) {
                    ipAddress = headers.get('X-Forwarded-For');
                }
                payload.put('ipAddress', ipAddress);
            }
        } catch (Exception ignore) {}
    }

    public static void publishSignerCommand(String action, ESignature_Envelope__c env, String token, Map<String, Object> payload, Boolean required) {
        ESignature_Command__e command = new ESignature_Command__e();
        command.Action__c = action;
        command.Token_Hash__c = hashToken(token);
        command.Envelope_Id__c = env == null ? null : String.valueOf(env.Id);
        command.Actor_Email__c = env == null ? null : env.Signer_Email__c;
        command.Payload_JSON__c = payload == null ? null : JSON.serialize(payload);
        Database.SaveResult result = EventBus.publish(command);
        if (!result.isSuccess() && required == true) {
            String message = 'Unable to submit the signing action.';
            if (result.getErrors() != null && !result.getErrors().isEmpty()) {
                message += ' ' + result.getErrors()[0].getMessage();
            }
            throw new AppException(message);
        }
    }

    public static String firstNonBlank(List<String> values) {
        if (values == null) {
            return null;
        }
        for (String value : values) {
            if (!String.isBlank(value)) {
                return value;
            }
        }
        return null;
    }

    public static String estimatePageCount(Blob pdfBlob) {
        if (pdfBlob == null) {
            return '1';
        }
        String asHex = EncodingUtil.convertToHex(pdfBlob);
        Integer count = 0;
        Set<Integer> pageMarkerIndexes = new Set<Integer>();
        for (String needle : new List<String>{
            EncodingUtil.convertToHex(Blob.valueOf('/Type/Page')),
            EncodingUtil.convertToHex(Blob.valueOf('/Type /Page')),
            EncodingUtil.convertToHex(Blob.valueOf('/Type  /Page')),
            EncodingUtil.convertToHex(Blob.valueOf('/Type' + '\t' + '/Page')),
            EncodingUtil.convertToHex(Blob.valueOf('/Type' + '\n' + '/Page')),
            EncodingUtil.convertToHex(Blob.valueOf('/Type' + '\r' + '/Page'))
        }) {
            Integer idx = asHex.indexOf(needle);
            while (idx >= 0) {
                String nextByte = idx + needle.length() + 2 <= asHex.length()
                    ? asHex.substring(idx + needle.length(), idx + needle.length() + 2)
                    : null;
                if (nextByte == null || nextByte.toLowerCase() != '73') {
                    pageMarkerIndexes.add(idx);
                }
                idx = asHex.indexOf(needle, idx + needle.length());
            }
        }
        count = pageMarkerIndexes.size();
        if (count <= 0) {
            count = 1;
        }
        return String.valueOf(count);
    }
}
