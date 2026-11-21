use futures::{SinkExt, StreamExt};
use reqwest::Url;
use rootcause::prelude::*;

use crate::net_policy;

/// The longest wait for one provisioning message from the anisette server.
const MESSAGE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

/// Text and close are messages; ping, pong and raw frames are not (`None`).
/// Binary is not part of the protocol: it ends the exchange like a close.
fn classify(message: tokio_tungstenite::tungstenite::Message) -> Option<WsMessage> {
    use tokio_tungstenite::tungstenite::Message;
    match message {
        Message::Text(text) => Some(WsMessage::Text(text.to_string())),
        Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => None,
        Message::Close(_) | Message::Binary(_) => Some(WsMessage::Close),
    }
}

#[derive(Debug, PartialEq)]
pub enum WsMessage {
    Text(String),
    Close,
}

pub struct AppWebSocket {
    inner: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
}

impl AppWebSocket {
    /// Zag Store fork: connects only over wss, only to the anisette server
    /// the provider was created for, and only in a live-network build.
    /// Upstream's relay option is removed.
    pub async fn connect(url: &str, anisette_url: &str) -> Result<Self, Report> {
        let target = Url::parse(url).map_err(|_| report!(net_policy::PolicyError::InvalidUrl))?;
        net_policy::permit_observed(&target, &[net_policy::host_of(anisette_url)?], "wss", "GET")?;

        use tokio::time::{Duration, timeout};

        let (stream, _) = timeout(
            Duration::from_secs(30),
            tokio_tungstenite::connect_async(target.as_str()),
        )
        .await?
        .context(
            "Timed out connecting to provisioning socket. Try a different anisette server.",
        )?;
        Ok(Self { inner: stream })
    }

    pub async fn send_text(&mut self, text: String) -> Result<(), Report> {
        self.inner
            .send(tokio_tungstenite::tungstenite::Message::Text(text.into()))
            .await?;
        Ok(())
    }

    /// The next text or close message. Zag Store fork: control frames are
    /// skipped (tungstenite answers pings itself), so a server keep-alive no
    /// longer ends provisioning as a close; and a server that goes quiet ends
    /// it after `MESSAGE_TIMEOUT` rather than never.
    pub async fn next(&mut self) -> Option<Result<WsMessage, Report>> {
        loop {
            let msg = match tokio::time::timeout(MESSAGE_TIMEOUT, self.inner.next()).await {
                Ok(msg) => msg?,
                Err(_) => return Some(Err(report!("Timed out waiting for the provisioning socket"))),
            };
            match msg.map(classify) {
                Ok(Some(message)) => return Some(Ok(message)),
                Ok(None) => continue,
                Err(error) => return Some(Err(error.into())),
            }
        }
    }

    pub async fn close(&mut self) -> Result<(), Report> {
        self.inner.close(None).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_tungstenite::tungstenite::Message;

    #[test]
    fn keep_alive_frames_do_not_end_provisioning() {
        assert_eq!(classify(Message::Ping(vec![1].into())), None);
        assert_eq!(classify(Message::Pong(vec![].into())), None);
        assert_eq!(classify(Message::Text("{}".into())), Some(WsMessage::Text("{}".into())));
        assert_eq!(classify(Message::Close(None)), Some(WsMessage::Close));
        assert_eq!(classify(Message::Binary(vec![0].into())), Some(WsMessage::Close));
    }
}
