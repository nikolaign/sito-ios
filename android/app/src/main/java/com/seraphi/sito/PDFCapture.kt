package com.seraphi.sito

import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.webkit.WebView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume

/** Render the loaded original publisher page, including its images, to a private PDF. */
internal suspend fun saveOriginalPDF(view: WebView, article: Article, pdfs: PDFStore) {
    val temporary = File.createTempFile("sito-original-", ".pdf", view.context.cacheDir)
    val attributes = PrintAttributes.Builder()
        .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
        .setResolution(PrintAttributes.Resolution("sito-pdf", "SITO", 300, 300))
        .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
        .build()
    val adapter = view.createPrintDocumentAdapter("SITO · ${article.title.take(70)}")
    val cancellation = CancellationSignal()
    try {
        suspendCancellableCoroutine<Unit> { continuation ->
            continuation.invokeOnCancellation { cancellation.cancel() }
            adapter.onStart()
            adapter.onLayout(null, attributes, cancellation,
                object : PrintDocumentAdapter.LayoutResultCallback() {
                    override fun onLayoutFinished(info: PrintDocumentInfo, changed: Boolean) {
                        if (!continuation.isActive) return
                        val descriptor = ParcelFileDescriptor.open(temporary,
                            ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_WRITE_ONLY or
                                ParcelFileDescriptor.MODE_TRUNCATE)
                        adapter.onWrite(arrayOf(PageRange.ALL_PAGES), descriptor, cancellation,
                            object : PrintDocumentAdapter.WriteResultCallback() {
                                override fun onWriteFinished(pages: Array<out PageRange>) {
                                    descriptor.close()
                                    if (continuation.isActive) continuation.resume(Unit)
                                }
                                override fun onWriteFailed(error: CharSequence?) {
                                    descriptor.close()
                                    if (continuation.isActive) continuation.resumeWith(Result.failure(
                                        IllegalStateException(error?.toString() ?: "PDF writing failed")))
                                }
                                override fun onWriteCancelled() {
                                    descriptor.close()
                                    if (continuation.isActive) continuation.resumeWith(Result.failure(
                                        IllegalStateException("PDF writing cancelled")))
                                }
                            })
                    }
                    override fun onLayoutFailed(error: CharSequence?) {
                        if (continuation.isActive) continuation.resumeWith(Result.failure(
                            IllegalStateException(error?.toString() ?: "PDF layout failed")))
                    }
                    override fun onLayoutCancelled() {
                        if (continuation.isActive) continuation.resumeWith(Result.failure(
                            IllegalStateException("PDF layout cancelled")))
                    }
                }, Bundle.EMPTY)
        }
        withContext(Dispatchers.IO) { pdfs.save(article.id, temporary.readBytes()) }
    } finally {
        adapter.onFinish()
        temporary.delete()
    }
}
