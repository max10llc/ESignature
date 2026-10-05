public without sharing class ESignatureSourceDeletionHandler {
    public static void closeUnsignedEnvelopes(Set<Id> documentIds) {
        Set<String> sourceIds = new Set<String>();
        for (Id documentId : documentIds) {
            sourceIds.add(String.valueOf(documentId));
        }
        Set<Id> legacyEnvelopeIds = new Set<Id>();
        for (ESignature_Field__c field : [
            SELECT Envelope__c FROM ESignature_Field__c
            WHERE Content_Document_Id__c IN :sourceIds
            WITH SYSTEM_MODE
        ]) {
            legacyEnvelopeIds.add(field.Envelope__c);
        }
        List<ESignature_Envelope__c> updates = new List<ESignature_Envelope__c>();
        List<ESignature_Audit_Event__c> audits = new List<ESignature_Audit_Event__c>();
        for (ESignature_Envelope__c env : [
            SELECT Id, Status__c FROM ESignature_Envelope__c
            WHERE (Source_ContentDocument_Id__c IN :sourceIds OR Id IN :legacyEnvelopeIds)
            AND Signed_At__c = null AND Status__c IN ('Draft', 'Sent', 'Viewed', 'Error')
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            env.Status__c = 'Canceled';
            env.Cancellation_Reason__c = 'The source document was deleted from Salesforce.';
            updates.add(env);
            audits.add(new ESignature_Audit_Event__c(
                Envelope__c = env.Id,
                Event_Type__c = 'Canceled',
                Actor_Email__c = UserInfo.getUserEmail(),
                Occurred_At__c = System.now(),
                Details__c = env.Cancellation_Reason__c
            ));
        }
        // Keep deletion and invalidation atomic: no active signing request can
        // survive a successful deletion of its source document.
        if (!updates.isEmpty()) {
            update as system updates;
            insert as system audits;
        }
    }
}
