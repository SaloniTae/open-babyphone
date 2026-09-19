package org.openbabyphone

import android.util.Base64
import java.net.URLEncoder
import java.security.SecureRandom

object InternetRelay {
    fun newSessionId(): String {
        val bytes = ByteArray(18)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(
            bytes,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        )
    }

    fun buildUrl(baseUrl: String, sessionId: String, role: String, token: String? = null): String {
        require(role == "child" || role == "parent")
        val separator = if (baseUrl.contains("?")) "&" else "?"
        val uri = baseUrl + separator +
            "session=" + URLEncoder.encode(sessionId, "UTF-8") +
            "&role=" + URLEncoder.encode(role, "UTF-8")
        return if (token.isNullOrBlank()) {
            uri
        } else {
            uri + "&token=" + URLEncoder.encode(token, "UTF-8")
        }
    }
}
