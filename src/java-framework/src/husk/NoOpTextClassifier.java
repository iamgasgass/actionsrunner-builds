package husk;

import android.view.textclassifier.*;

/** TextClassifier.NO_OP, as Android's is: it recognises nothing, and says so with a real (empty) answer to every request
 *  rather than null, so TextView's selection, links and smart actions -- and apps that ask directly -- carry on unchanged. */
public final class NoOpTextClassifier implements TextClassifier {
    public NoOpTextClassifier() {}
    @Override public TextSelection suggestSelection(TextSelection.Request r) {
        return new TextSelection.Builder(r != null ? r.getStartIndex() : 0, r != null ? r.getEndIndex() : 0).build();
    }
    @Override public TextSelection suggestSelection(CharSequence text, int start, int end, android.os.LocaleList locales) {
        return new TextSelection.Builder(start, end).build();
    }
    @Override public TextClassification classifyText(TextClassification.Request r) { return new TextClassification.Builder().build(); }
    @Override public TextClassification classifyText(CharSequence text, int start, int end, android.os.LocaleList locales) { return new TextClassification.Builder().build(); }
    @Override public TextLinks generateLinks(TextLinks.Request r) {
        CharSequence t = r != null ? r.getText() : null;
        return new TextLinks.Builder(t != null ? t.toString() : "").build();
    }
    @Override public int getMaxGenerateLinksTextLength() { return 100 * 1000; }
    @Override public TextLanguage detectLanguage(TextLanguage.Request r) { return new TextLanguage.Builder().build(); }
    @Override public ConversationActions suggestConversationActions(ConversationActions.Request r) { return new ConversationActions(new java.util.ArrayList(), null); }
    @Override public String toString() { return "TextClassifier.NO_OP"; }
}
