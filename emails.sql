CREATE TABLE IF NOT EXISTS `email_sender_rate` (
  `sender_rate_id` int(11) NOT NULL,
  `domain` varchar(65) NOT NULL,
  `message_quota` int(10) NOT NULL DEFAULT '0',
  `message_tally` int(10) NOT NULL DEFAULT '0',
  `timestamp` int(10) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;


--
-- Index for table `email_sender_rate`
--
ALTER TABLE `email_sender_rate`
  ADD PRIMARY KEY (`sender_rate_id`);

--
-- AUTO_INCREMENT for table `email_sender_rate`
--
ALTER TABLE `email_sender_rate`
  MODIFY `sender_rate_id` int(11) NOT NULL AUTO_INCREMENT;
