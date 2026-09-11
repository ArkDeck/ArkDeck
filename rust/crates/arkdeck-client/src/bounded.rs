//! Opt-in total budget. The original Client::connect keeps its per-IO timeout.
use crate::{Client, ClientError};
use arkdeck_platform::{LocalConnection, LocalEndpoint, ServerIdentity};
use std::io::{self, Read, Write};
use std::time::{Duration, Instant};

pub(crate) fn remaining(deadline: Instant) -> io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "control deadline exceeded"))
}

/// Authenticated local transport whose individual IO calls share one deadline.
pub struct BoundedConnection {
    connection: LocalConnection,
    deadline: Instant,
}

impl Client<BoundedConnection> {
    /// Connection/authentication elapsed time, health and all request IO consume
    /// one budget. Late replies cannot succeed and an expired client cannot retry.
    pub fn connect_bounded(
        endpoint: &LocalEndpoint,
        identity: &ServerIdentity,
        timeout: Duration,
    ) -> Result<Self, ClientError> {
        let deadline = Instant::now().checked_add(timeout).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "control deadline overflows")
        })?;
        remaining(deadline)?;
        let connection = LocalConnection::connect(endpoint, identity)?;
        remaining(deadline)?;
        let mut client = Self::new(BoundedConnection {
            connection,
            deadline,
        });
        client.deadline = Some(deadline);
        Ok(client)
    }
}

impl Read for BoundedConnection {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.connection
            .set_read_timeout(Some(remaining(self.deadline)?))?;
        let result = self.connection.read(bytes);
        remaining(self.deadline)?;
        result
    }
}

impl Write for BoundedConnection {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.connection
            .set_write_timeout(Some(remaining(self.deadline)?))?;
        let result = self.connection.write(bytes);
        remaining(self.deadline)?;
        result
    }

    fn flush(&mut self) -> io::Result<()> {
        remaining(self.deadline)?;
        let result = self.connection.flush();
        remaining(self.deadline)?;
        result
    }
}
