package com.kapybara.kapynotes.translation

import android.content.Context
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import com.kapybara.kapynotes.OnDeviceTranslationPack
import com.kapybara.kapynotes.PhraseTranslator

/**
 * ML Kit's on-device translator, for the base app's LiveTranslation.
 *
 * Made by name, through its one constructor, once Play has delivered this
 * module and SplitCompat has made it loadable: the base app has none of ML
 * Kit's translation code, and knows this only as [OnDeviceTranslationPack].
 * Kept by name in the base app's proguard-rules.pro for that reason.
 *
 * Language models download only when asked to, through [download], and stay
 * until [remove]. ML Kit's tasks answer on the main thread, which is where the
 * base wants every answer. Nothing translated is logged.
 */
class MlKitTranslationPack(@Suppress("UNUSED_PARAMETER") context: Context) : OnDeviceTranslationPack {
    private val models: RemoteModelManager
        get() = RemoteModelManager.getInstance()

    override fun missing(languages: List<String>, done: (List<String>?) -> Unit) {
        val wanted = languages.map { TranslateLanguage.fromLanguageTag(it) ?: return done(null) }
        try {
            models.getDownloadedModels(TranslateRemoteModel::class.java)
                .addOnSuccessListener { downloaded ->
                    val present = downloaded.map { it.language }.toSet()
                    done(wanted.filter { it !in present })
                }
                .addOnFailureListener { done(null) }
        } catch (error: RuntimeException) {
            done(null)
        }
    }

    override fun download(from: String, to: String, wifiOnly: Boolean, done: (Boolean) -> Unit) {
        val translator = client(from, to) ?: return done(false)
        val conditions = DownloadConditions.Builder().apply { if (wifiOnly) requireWifi() }.build()
        translator.downloadModelIfNeeded(conditions)
            .addOnCompleteListener { task ->
                translator.close()
                done(task.isSuccessful)
            }
    }

    override fun remove(language: String, done: () -> Unit) {
        val code = TranslateLanguage.fromLanguageTag(language) ?: return done()
        try {
            models.deleteDownloadedModel(TranslateRemoteModel.Builder(code).build())
                .addOnCompleteListener { done() }
        } catch (error: RuntimeException) {
            done()
        }
    }

    override fun open(from: String, to: String): PhraseTranslator? {
        val translator = client(from, to) ?: return null
        return object : PhraseTranslator {
            override fun translate(text: String, done: (String?) -> Unit) {
                translator.translate(text)
                    .addOnCompleteListener { task -> done(if (task.isSuccessful) task.result else null) }
            }

            override fun close() = translator.close()
        }
    }

    /**
     * Null for a language ML Kit doesn't know, or when ML Kit can't start: a
     * module that arrived in this session before its components were found
     * is the case to expect, and the next launch finds them.
     */
    private fun client(from: String, to: String): Translator? {
        val source = TranslateLanguage.fromLanguageTag(from) ?: return null
        val target = TranslateLanguage.fromLanguageTag(to) ?: return null
        return try {
            Translation.getClient(
                TranslatorOptions.Builder()
                    .setSourceLanguage(source)
                    .setTargetLanguage(target)
                    .build(),
            )
        } catch (error: RuntimeException) {
            null
        }
    }
}
