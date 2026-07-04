public without sharing class ESignatureUtil {
    private static final Integer SOURCE_PDF_CHUNK_SIZE = 100000;
    public class AppException extends Exception {}

    public static ESignature_Setting__mdt getSettings() {
        List<ESignature_Setting__mdt> rows = [
            SELECT Site_Base_URL__c,
                   Finalizer_Named_Credential__c,
                   Finalizer_Mode__c,
                   Finalizer_Callback_URL__c,
                   Finalizer_Callback_Secret__c,
                   Include_Source_PDF_In_Finalizer_Request__c,
                   Default_From_Email__c,
                   Default_Expiration_Days__c,
                   Restrict_Editing__c,
                   Restrict_Copying__c,
                   Allow_Low_Quality_Printing__c,
                   Final_Pdf_Owner_Password__c
            FROM ESignature_Setting__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new AppException('Missing ESignature_Setting__mdt record named Default.');
        }
        return rows[0];
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

    public static ESignature_Envelope__c findEnvelopeByToken(String token) {
        String hashValue = hashToken(token);
        if (String.isBlank(hashValue)) {
            return null;
        }
        List<ESignature_Envelope__c> rows = [
            SELECT Id, Name, Envelope_Status__c, Parent_Record_Id__c, Parent_Object_Api_Name__c,
                   Final_ContentDocument_Id__c, Final_ContentVersion_Id__c, Secure_Token_Hash__c,
                   Signer_Name__c, Signer_Email__c, Signer_Title__c, Sender_User__c,
                   Source_File_Title__c, Source_ContentVersion_Id__c, Source_ContentDocument_Id__c,
                   Sent_At__c, Viewed_At__c, Signed_At__c, Expires_At__c, Page_Count__c,
                   Public_Signing_URL__c, Signature_Method__c, Signature_Image_Data_Url__c,
                   Completed_Fields_JSON__c, Completion_Message__c, Decline_Reason__c, Error_Message__c
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
        env.Parent_Record_Id__c = parentRecordId;
        Id parentId = safeId(parentRecordId);
        String parentObjectApiName = parentId == null ? null : parentId.getSObjectType().getDescribe().getName();
        env.Parent_Object_Api_Name__c = parentObjectApiName;
        env.Account__c = null;
        env.Opportunity__c = null;
        env.Work_Order__c = null;
        if (parentId == null || String.isBlank(parentObjectApiName)) {
            return;
        }
        if (parentObjectApiName == 'Account') {
            env.Account__c = parentId;
        } else if (parentObjectApiName == 'Opportunity') {
            env.Opportunity__c = parentId;
        } else if (parentObjectApiName == 'WorkOrder') {
            env.Work_Order__c = parentId;
        }
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
