use futures::{SinkExt, StreamExt};
use reqwest::Url;
use rootcause::prelude::*;

use crate::net_policy;

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

    pub async fn next(&mut self) -> Option<Result<WsMessage, Report>> {
        let msg = self.inner.next().await?;
        Some(msg.map_err(Into::into).map(|m| match m {
            tokio_tungstenite::tungstenite::Message::Text(t) => WsMessage::Text(t.to_string()),
            tokio_tungstenite::tungstenite::Message::Close(_) => WsMessage::Close,
            _ => WsMessage::Close,
        }))
    }

    pub async fn close(&mut self) -> Result<(), Report> {
        self.inner.close(None).await?;
        Ok(())
    }
}
