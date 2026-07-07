import { LightningElement, api, track } from 'lwc';
import Toast from 'lightning/toast';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

import getDraftEnvelopes from '@salesforce/apex/ESignatureSendController.getDraftEnvelopes';
import getSignerContacts from '@salesforce/apex/ESignatureSendController.getSignerContacts';
import sendEnvelope from '@salesforce/apex/ESignatureSendController.sendEnvelope';

export default class PdfESignSendEnvelope extends LightningElement {
    _recordId;
    _parentRecordId;

    @api documentSent = false;

    @track envelopes = [];
    @track signerContacts = [];
    selectedEnvelopeId;
    selectedContactId;
    signerName = '';
    signerEmail = '';
    signerTitle = '';
    requestSubject = '';
    requestMessage = 'Please review and sign the agreement.';
    expirationDays = 365;
    isLoading = true;
    isSending = false;
    errorMessage;
    draftRefreshKey = 'initial';
    hasConnected = false;
    initialLoadQueued = false;
    loadedParentRecordId;

    connectedCallback() {
        this.hasConnected = true;
        this.queueInitialDraftLoad();
    }

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;
        this.queueInitialDraftLoad();
    }

    @api
    get parentRecordId() {
        return this._parentRecordId;
    }

    set parentRecordId(value) {
        this._parentRecordId = value;
        this.queueInitialDraftLoad();
    }

    get effectiveParentRecordId() {
        return this._parentRecordId || this._recordId;
    }

    get hasDrafts() {
        return this.envelopes.length > 0;
    }

    get currentDraft() {
        return this.envelopes.length ? this.envelopes[0] : null;
    }

    get hasSignerContacts() {
        return this.signerContacts.length > 0;
    }

    get contactOptions() {
        return this.signerContacts.map((contact) => ({
            label: contact.label || `${contact.name} (${contact.email})`,
            value: contact.id
        }));
    }

    get selectedContact() {
        return this.signerContacts.find((contact) => contact.id === this.selectedContactId);
    }

    get selectedContactEmail() {
        const contact = this.selectedContact;
        return contact ? contact.email : '';
    }

    get selectedContactTitle() {
        const contact = this.selectedContact;
        return contact ? contact.title : '';
    }

    get disableSend() {
        return this.isSending || !this.selectedEnvelopeId || !this.selectedContactId || !this.signerName || !this.signerEmail || !this.requestSubject?.trim();
    }

    queueInitialDraftLoad() {
        if (!this.hasConnected || this.initialLoadQueued) {
            return;
        }
        this.initialLoadQueued = true;
        Promise.resolve().then(() => {
            this.initialLoadQueued = false;
            this.loadInitialDrafts();
        });
    }

    loadInitialDrafts() {
        const parentRecordId = this.effectiveParentRecordId;
        if (!parentRecordId) {
            this.envelopes = [];
            this.signerContacts = [];
            this.selectedEnvelopeId = null;
            this.selectedContactId = null;
            this.clearSigner();
            this.isLoading = false;
            return;
        }
        if (this.loadedParentRecordId === parentRecordId) {
            return;
        }
        this.loadedParentRecordId = parentRecordId;
        this.loadDrafts(true);
    }

    async loadDrafts(forceRefresh = false) {
        this.isLoading = true;
        this.errorMessage = null;
        try {
            const parentRecordId = this.effectiveParentRecordId;
            if (!parentRecordId) {
                this.envelopes = [];
                this.signerContacts = [];
                this.selectedEnvelopeId = null;
                this.selectedContactId = null;
                this.clearSigner();
                return;
            }
            if (forceRefresh) {
                this.draftRefreshKey = String(Date.now());
            }
            const [envelopes, signerContacts] = await Promise.all([
                getDraftEnvelopes({
                    parentRecordId,
                    refreshKey: this.draftRefreshKey
                }),
                getSignerContacts({
                    parentRecordId,
                    refreshKey: this.draftRefreshKey
                })
            ]);
            this.envelopes = envelopes || [];
            this.signerContacts = signerContacts || [];
            this.selectedEnvelopeId = this.currentDraft ? this.currentDraft.id : null;
            this.syncSelectedContact();
        } catch (error) {
            this.errorMessage = this.normalizeError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleSignerContactChange(event) {
        this.selectedContactId = event.detail.value;
        this.applySelectedContact();
    }

    handleRequestMessageChange(event) {
        this.requestMessage = event.detail.value;
    }

    handleRequestSubjectChange(event) {
        this.requestSubject = event.detail.value;
    }

    handleExpirationChange(event) {
        this.expirationDays = Number(event.detail.value) || 365;
    }

    syncSelectedContact() {
        if (this.selectedContactId && this.selectedContact) {
            this.applySelectedContact();
            return;
        }
        this.selectedContactId = null;
        this.clearSigner();
    }

    applySelectedContact() {
        const contact = this.selectedContact;
        if (!contact) {
            this.clearSigner();
            return;
        }
        this.signerName = contact.name || '';
        this.signerEmail = contact.email || '';
        this.signerTitle = contact.title || '';
    }

    clearSigner() {
        this.signerName = '';
        this.signerEmail = '';
        this.signerTitle = '';
    }

    async handleSend() {
        this.isSending = true;
        this.errorMessage = null;
        this.setDocumentSent(false);
        try {
            await sendEnvelope({
                envelopeId: this.selectedEnvelopeId,
                signerName: this.signerName,
                signerEmail: this.signerEmail,
                signerTitle: this.signerTitle,
                requestSubject: this.requestSubject,
                requestMessage: this.requestMessage,
                expirationDays: this.expirationDays
            });
            this.setDocumentSent(true);
            this.showToast('Document sent', 'The document has been sent for signature.', 'success');
        } catch (error) {
            this.errorMessage = this.normalizeError(error);
            this.showToast('Unable to send envelope', this.errorMessage, 'error', 'sticky');
        } finally {
            this.isSending = false;
        }
    }

    setDocumentSent(value) {
        this.documentSent = value;
        this.dispatchEvent(new FlowAttributeChangeEvent('documentSent', this.documentSent));
    }

    showToast(title, message, variant, mode = 'dismissible') {
        try {
            Toast.show({
                label: title,
                message,
                variant,
                mode
            }, this);
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
        }
    }

    normalizeError(error) {
        if (!error) {
            return 'Unknown error';
        }
        if (Array.isArray(error.body)) {
            return error.body.map((item) => item.message).join(', ');
        }
        if (error.body && error.body.message) {
            return error.body.message;
        }
        return error.message || String(error);
    }
}
