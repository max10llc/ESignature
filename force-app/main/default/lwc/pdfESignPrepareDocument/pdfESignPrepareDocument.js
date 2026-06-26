import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getRecordPdfFiles from '@salesforce/apex/PDFESignaturePrepareController.getRecordPdfFiles';
import getPdfDocumentInfo from '@salesforce/apex/PDFESignaturePrepareController.getPdfDocumentInfo';
import getPlacements from '@salesforce/apex/PDFESignaturePrepareController.getPlacements';
import savePlacements from '@salesforce/apex/PDFESignaturePrepareController.savePlacements';

const FIELD_TYPES = [
    { label: 'Signature', value: 'Signature', width: 0.28, height: 0.055 },
    { label: 'Initials', value: 'Initials', width: 0.12, height: 0.045 },
    { label: 'Date', value: 'Date', width: 0.16, height: 0.04 },
    { label: 'Name', value: 'Name', width: 0.22, height: 0.04 },
    { label: 'Title', value: 'Title', width: 0.22, height: 0.04 },
    { label: 'Text', value: 'Text', width: 0.24, height: 0.04 },
    { label: 'Checkbox', value: 'Checkbox', width: 0.045, height: 0.04 }
];

const MIN_FIELD_WIDTH = 0.025;
const MIN_FIELD_HEIGHT = 0.025;
const DRAG_THRESHOLD_PIXELS = 6;

export default class PdfESignPrepareDocument extends LightningElement {
    @api recordId;
    @api parentRecordId;
    @api contentDocumentId;
    @api height = 760;

    @track pages = [];
    @track fields = [];
    @track fileOptions = [];

    selectedContentDocumentId;
    selectedContentVersionId;
    fieldTypes = FIELD_TYPES;
    pdfInfo;
    loadError;
    warningMessage;
    selectedFieldId;
    pendingFieldType;
    draggedFieldType;
    isLoading = true;
    isSaving = false;
    loadingMessage = 'Starting document preparation...';
    zoom = 1.25;
    pageDimensions = new Map();
    pointerState;
    nextClientId = 1;
    hasInitialized = false;

    connectedCallback() {
        this.boundHandlePointerMove = this.handlePointerMove.bind(this);
        this.boundHandlePointerUp = this.handlePointerUp.bind(this);
        this.boundHandlePointerCancel = this.handlePointerUp.bind(this);
    }

    renderedCallback() {
        if (this.hasInitialized) {
            return;
        }
        this.hasInitialized = true;
        this.initialize();
    }

    disconnectedCallback() {
        this.removePointerListeners();
    }

    get effectiveParentRecordId() {
        return this.parentRecordId || this.recordId;
    }

    get activeContentDocumentId() {
        return this.contentDocumentId || this.selectedContentDocumentId;
    }

    get documentShellStyle() {
        return `max-height: ${this.height}px;`;
    }

    get zoomPercent() {
        return Math.round(this.zoom * 100);
    }

    get noSelectedField() {
        return !this.selectedFieldId;
    }

    get selectedField() {
        return this.fields.find((field) => field.clientId === this.selectedFieldId);
    }

    get showClickToPlaceMessage() {
        return !!this.pendingFieldType;
    }

    get pendingFieldTypeLabel() {
        const fieldType = FIELD_TYPES.find((item) => item.value === this.pendingFieldType);
        return fieldType ? fieldType.label : '';
    }

    get hasSelectedPdf() {
        return !!this.pdfInfo;
    }

    get pagesWithFields() {
        return this.pages.map((page) => {
            const pageFields = this.fields
                .filter((field) => field.pageNumber === page.pageNumber)
                .map((field) => ({
                    ...field,
                    className: `placed-field ${field.clientId === this.selectedFieldId ? 'selected' : ''} type-${field.fieldType.toLowerCase()}`,
                    displayLabel: field.label || field.fieldType,
                    style: [
                        `left: ${field.xPercent * 100}%`,
                        `top: ${field.yPercent * 100}%`,
                        `width: ${field.widthPercent * 100}%`,
                        `height: ${field.heightPercent * 100}%`
                    ].join(';')
                }));
            return { ...page, fields: pageFields };
        });
    }

    async initialize() {
        this.isLoading = true;
        this.loadError = null;
        try {
            if (!this.effectiveParentRecordId) {
                throw new Error('Parent Record Id is required. Put this component on a record page or pass recordId from Flow.');
            }
            await this.loadRecordFiles();
            if (this.contentDocumentId) {
                this.selectedContentDocumentId = this.contentDocumentId;
                await this.loadSelectedPdf();
            }
        } catch (error) {
            this.loadError = this.normalizeError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadRecordFiles() {
        this.loadingMessage = 'Loading related PDF files...';
        const files = await getRecordPdfFiles({ recordId: this.effectiveParentRecordId });
        this.fileOptions = files.map((file) => ({
            label: file.title,
            value: file.contentDocumentId,
            contentVersionId: file.contentVersionId
        }));
        if (!this.contentDocumentId && this.fileOptions.length === 1) {
            this.selectedContentDocumentId = this.fileOptions[0].value;
            this.selectedContentVersionId = this.fileOptions[0].contentVersionId;
            await this.loadSelectedPdf();
        }
    }

    async handleFileChange(event) {
        this.selectedContentDocumentId = event.detail.value;
        const selected = this.fileOptions.find((item) => item.value === this.selectedContentDocumentId);
        this.selectedContentVersionId = selected ? selected.contentVersionId : null;
        await this.loadSelectedPdf();
    }

    async loadSelectedPdf() {
        this.isLoading = true;
        this.loadError = null;
        this.fields = [];
        this.pages = [];
        try {
            if (!this.activeContentDocumentId) {
                return;
            }
            this.loadingMessage = 'Loading PDF information...';
            this.pdfInfo = await this.withTimeout(
                getPdfDocumentInfo({ contentDocumentId: this.activeContentDocumentId }),
                20000,
                'Loading PDF information'
            );
            this.selectedContentVersionId = this.pdfInfo.contentVersionId;
            this.loadingMessage = 'Preparing page previews...';
            this.initializeRenditionPreview();
            this.loadingMessage = 'Loading saved field placements...';
            await this.withTimeout(this.loadExistingPlacements(), 20000, 'Loading saved field placements');
            this.loadingMessage = 'Rendering PDF pages...';
            await this.renderAllPages();
        } catch (error) {
            this.loadError = this.normalizeError(error);
        } finally {
            this.isLoading = false;
        }
    }

    initializeRenditionPreview() {
        const pageCount = Math.max(Number(this.pdfInfo?.pageCount) || 1, 1);
        this.pages = Array.from({ length: pageCount }, (_, index) => ({
            pageNumber: index + 1,
            pageIndex: index,
            renditionUrl: this.buildRenditionUrl('SVGZ', index),
            fallbackRenditionUrl: this.buildRenditionUrl('THUMB720BY480', index),
            hasTriedFallback: false,
            altText: `PDF page ${index + 1}`
        }));
    }

    buildRenditionUrl(rendition, pageIndex) {
        const params = new URLSearchParams({
            rendition,
            versionId: this.pdfInfo.contentVersionId,
            operationContext: 'CHATTER',
            page: String(pageIndex)
        });
        return `/sfc/servlet.shepherd/version/renditionDownload?${params.toString()}`;
    }

    async loadExistingPlacements() {
        const existingPlacements = await getPlacements({
            parentRecordId: this.effectiveParentRecordId,
            contentDocumentId: this.activeContentDocumentId
        });
        this.fields = existingPlacements.map((placement) => ({
            clientId: this.newClientId(),
            serverId: placement.id,
            fieldType: placement.fieldType,
            pageNumber: placement.pageNumber,
            xPercent: Number(placement.xPercent),
            yPercent: Number(placement.yPercent),
            widthPercent: Number(placement.widthPercent),
            heightPercent: Number(placement.heightPercent),
            signerNumber: placement.signerNumber || 1,
            required: placement.required !== false,
            label: placement.label || placement.fieldType
        }));
    }

    async renderAllPages() {
        await this.withTimeout(this.waitForRender(), 10000, 'Waiting for pages to render');
        this.pageDimensions = new Map();
        for (const page of this.pages) {
            this.configureRenditionPage(page.pageNumber, 612, 792);
            this.pageDimensions.set(page.pageNumber, { width: 612, height: 792 });
        }
    }

    configureRenditionPage(pageNumber, pdfWidth, pdfHeight) {
        const pageShell = this.template.querySelector(`section[data-page-number="${pageNumber}"]`);
        if (!pageShell) {
            return;
        }
        pageShell.style.width = `${pdfWidth * this.zoom}px`;
        pageShell.style.height = `${pdfHeight * this.zoom}px`;
    }

    handleRenditionLoad(event) {
        const image = event.currentTarget;
        const pageNumber = Number(image.dataset.pageNumber);
        const naturalWidth = image.naturalWidth || 612;
        const naturalHeight = image.naturalHeight || 792;
        const pdfWidth = 612;
        const pdfHeight = Math.round((pdfWidth * naturalHeight) / naturalWidth);
        this.configureRenditionPage(pageNumber, pdfWidth, pdfHeight);
        this.pageDimensions.set(pageNumber, { width: pdfWidth, height: pdfHeight });
    }

    handleRenditionError(event) {
        const pageNumber = Number(event.currentTarget.dataset.pageNumber);
        this.pages = this.pages.map((page) => {
            if (page.pageNumber !== pageNumber || page.hasTriedFallback) {
                return page;
            }
            return { ...page, renditionUrl: page.fallbackRenditionUrl, hasTriedFallback: true };
        });
        if (!this.warningMessage) {
            this.warningMessage = 'One or more page previews are still being generated by Salesforce. If a page is blank, wait a moment and reopen this screen.';
        }
    }

    handlePaletteDragStart(event) {
        this.draggedFieldType = event.currentTarget.dataset.fieldType;
        event.dataTransfer.setData('text/plain', this.draggedFieldType);
        event.dataTransfer.effectAllowed = 'copy';
    }

    handlePaletteClick(event) {
        this.pendingFieldType = event.currentTarget.dataset.fieldType;
    }

    handlePageDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'copy';
    }

    handlePageDrop(event) {
        event.preventDefault();
        const fieldType = event.dataTransfer.getData('text/plain') || this.draggedFieldType;
        this.addFieldFromEvent(fieldType, event);
        this.draggedFieldType = null;
    }

    handlePageClick(event) {
        if (!this.pendingFieldType) {
            if (!event.target.closest('.placed-field')) {
                this.selectedFieldId = null;
            }
            return;
        }
        this.addFieldFromEvent(this.pendingFieldType, event);
        this.pendingFieldType = null;
    }

    addFieldFromEvent(fieldType, event) {
        if (!fieldType) {
            return;
        }
        const pageShell = event.currentTarget;
        const pageNumber = Number(pageShell.dataset.pageNumber);
        const rect = pageShell.getBoundingClientRect();
        const config = FIELD_TYPES.find((item) => item.value === fieldType);
        const widthPercent = config ? config.width : 0.2;
        const heightPercent = config ? config.height : 0.04;
        const xPercent = this.clamp((event.clientX - rect.left) / rect.width - widthPercent / 2, 0, 1 - widthPercent);
        const yPercent = this.clamp((event.clientY - rect.top) / rect.height - heightPercent / 2, 0, 1 - heightPercent);
        const field = {
            clientId: this.newClientId(), fieldType, pageNumber, xPercent, yPercent,
            widthPercent, heightPercent, signerNumber: 1, required: true, label: fieldType
        };
        this.fields = [...this.fields, field];
        this.selectedFieldId = field.clientId;
    }

    handleFieldClick(event) {
        event.stopPropagation();
        this.selectedFieldId = event.currentTarget.dataset.clientId;
    }

    handleFieldPointerDown(event) {
        event.preventDefault();
        event.stopPropagation();
        const clientId = event.currentTarget.dataset.clientId;
        const field = this.fields.find((item) => item.clientId === clientId);
        const pageShell = this.template.querySelector(`section[data-page-number="${field.pageNumber}"]`);
        const rect = pageShell.getBoundingClientRect();
        this.selectedFieldId = clientId;
        this.pointerState = { action: 'move', clientId, startX: event.clientX, startY: event.clientY, startField: { ...field }, pageRect: rect, hasMoved: false };
        this.addPointerListeners();
    }

    handleResizePointerDown(event) {
        event.preventDefault();
        event.stopPropagation();
        const clientId = event.currentTarget.dataset.clientId;
        const field = this.fields.find((item) => item.clientId === clientId);
        const pageShell = this.template.querySelector(`section[data-page-number="${field.pageNumber}"]`);
        const rect = pageShell.getBoundingClientRect();
        this.selectedFieldId = clientId;
        this.pointerState = { action: 'resize', clientId, startX: event.clientX, startY: event.clientY, startField: { ...field }, pageRect: rect, hasMoved: false };
        this.addPointerListeners();
    }

    handlePointerMove(event) {
        if (!this.pointerState) {
            return;
        }
        const deltaXPercent = (event.clientX - this.pointerState.startX) / this.pointerState.pageRect.width;
        const deltaYPercent = (event.clientY - this.pointerState.startY) / this.pointerState.pageRect.height;
        const movedPixels = Math.abs(event.clientX - this.pointerState.startX) + Math.abs(event.clientY - this.pointerState.startY);
        if (!this.pointerState.hasMoved && movedPixels <= DRAG_THRESHOLD_PIXELS) {
            return;
        }
        this.pointerState.hasMoved = true;
        this.fields = this.fields.map((field) => {
            if (field.clientId !== this.pointerState.clientId) {
                return field;
            }
            if (this.pointerState.action === 'move') {
                return {
                    ...field,
                    xPercent: this.clamp(this.pointerState.startField.xPercent + deltaXPercent, 0, 1 - field.widthPercent),
                    yPercent: this.clamp(this.pointerState.startField.yPercent + deltaYPercent, 0, 1 - field.heightPercent)
                };
            }
            return {
                ...field,
                widthPercent: this.clamp(this.pointerState.startField.widthPercent + deltaXPercent, MIN_FIELD_WIDTH, 1 - this.pointerState.startField.xPercent),
                heightPercent: this.clamp(this.pointerState.startField.heightPercent + deltaYPercent, MIN_FIELD_HEIGHT, 1 - this.pointerState.startField.yPercent)
            };
        });
    }

    handlePointerUp() {
        if (this.pointerState && !this.pointerState.hasMoved) {
            this.selectedFieldId = this.pointerState.clientId;
        }
        this.pointerState = null;
        this.removePointerListeners();
    }

    addPointerListeners() {
        window.addEventListener('pointermove', this.boundHandlePointerMove);
        window.addEventListener('pointerup', this.boundHandlePointerUp);
        window.addEventListener('pointercancel', this.boundHandlePointerCancel);
        window.addEventListener('blur', this.boundHandlePointerCancel);
    }

    removePointerListeners() {
        window.removeEventListener('pointermove', this.boundHandlePointerMove);
        window.removeEventListener('pointerup', this.boundHandlePointerUp);
        window.removeEventListener('pointercancel', this.boundHandlePointerCancel);
        window.removeEventListener('blur', this.boundHandlePointerCancel);
    }

    handleDeleteSelected() {
        if (!this.selectedFieldId) {
            return;
        }
        this.fields = this.fields.filter((field) => field.clientId !== this.selectedFieldId);
        this.selectedFieldId = null;
    }

    handleSelectedLabelChange(event) {
        this.updateSelectedField({ label: event.detail.value });
    }

    handleSelectedSignerChange(event) {
        this.updateSelectedField({ signerNumber: Math.max(1, Number(event.detail.value) || 1) });
    }

    handleSelectedRequiredChange(event) {
        this.updateSelectedField({ required: event.detail.checked });
    }

    updateSelectedField(changes) {
        if (!this.selectedFieldId) {
            return;
        }
        this.fields = this.fields.map((field) => (field.clientId === this.selectedFieldId ? { ...field, ...changes } : field));
    }

    async handleZoomOut() {
        this.zoom = Math.max(0.75, this.zoom - 0.1);
        await this.renderAllPages();
    }

    async handleZoomIn() {
        this.zoom = Math.min(2.25, this.zoom + 0.1);
        await this.renderAllPages();
    }

    async handleSave() {
        this.isSaving = true;
        try {
            const placements = this.fields.map((field) => this.toPlacementPayload(field));
            const result = await savePlacements({
                parentRecordId: this.effectiveParentRecordId,
                contentDocumentId: this.activeContentDocumentId,
                contentVersionId: this.pdfInfo.contentVersionId,
                placementsJson: JSON.stringify(placements)
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Fields saved', message: result.message, variant: 'success' }));
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Unable to save fields', message: this.normalizeError(error), variant: 'error', mode: 'sticky' }));
        } finally {
            this.isSaving = false;
        }
    }

    toPlacementPayload(field) {
        const pageDimension = this.pageDimensions.get(field.pageNumber);
        const pdfWidth = pageDimension ? pageDimension.width : 612;
        const pdfHeight = pageDimension ? pageDimension.height : 792;
        return {
            fieldType: field.fieldType,
            pageNumber: field.pageNumber,
            xPercent: this.round(field.xPercent),
            yPercent: this.round(field.yPercent),
            widthPercent: this.round(field.widthPercent),
            heightPercent: this.round(field.heightPercent),
            signerNumber: field.signerNumber || 1,
            required: field.required !== false,
            label: field.label || field.fieldType,
            pdfX: this.round(field.xPercent * pdfWidth, 2),
            pdfY: this.round(pdfHeight - ((field.yPercent + field.heightPercent) * pdfHeight), 2),
            pdfWidth: this.round(field.widthPercent * pdfWidth, 2),
            pdfHeight: this.round(field.heightPercent * pdfHeight, 2)
        };
    }

    newClientId() {
        const value = `field-${this.nextClientId}`;
        this.nextClientId += 1;
        return value;
    }

    waitForRender() {
        return new Promise((resolve) => window.requestAnimationFrame(() => resolve()));
    }

    withTimeout(promise, milliseconds, label) {
        let timeoutId;
        const timeout = new Promise((resolve, reject) => {
            timeoutId = window.setTimeout(() => reject(new Error(`${label} timed out after ${Math.round(milliseconds / 1000)} seconds.`)), milliseconds);
        });
        return Promise.race([promise, timeout]).finally(() => window.clearTimeout(timeoutId));
    }

    clamp(value, min, max) {
        return Math.min(Math.max(value, min), max);
    }

    round(value, decimals = 8) {
        const factor = 10 ** decimals;
        return Math.round(Number(value) * factor) / factor;
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