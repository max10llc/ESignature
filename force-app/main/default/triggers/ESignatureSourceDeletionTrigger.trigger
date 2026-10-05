trigger ESignatureSourceDeletionTrigger on ContentDocument (after delete) {
    ESignatureSourceDeletionHandler.closeUnsignedEnvelopes(Trigger.oldMap.keySet());
}
