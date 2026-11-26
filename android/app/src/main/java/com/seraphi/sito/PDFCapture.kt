package com.seraphi.sito

import android.content.Context
import android.print.PrintAttributes
import android.print.PrintManager
import android.webkit.WebView

/** Android's supported way to save the actual rendered website, with images. */
internal fun printOriginalPage(view: WebView, article: Article) {
    val printer = view.context.getSystemService(Context.PRINT_SERVICE) as PrintManager
    val name = "SITO - ${article.title.take(70)}"
    printer.print(name, view.createPrintDocumentAdapter(name),
        PrintAttributes.Builder().setMediaSize(PrintAttributes.MediaSize.ISO_A4).build())
}
